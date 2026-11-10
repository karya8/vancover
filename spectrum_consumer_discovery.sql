/* =====================================================================
   FX Spectrum migration - consumer discovery queries
   Purpose: find every user, service account, job, report and downstream
            object that reads the Spectrum tables, on both platforms.
   Placeholders:  <uc_catalog>   Unity Catalog catalog holding fx_spectrum
                  <SpectrumDB>   on-prem SQL Server database name
                  <AuditPath>    folder for SQL Server Audit files
   Run against PRODUCTION metadata. Dev/SIT only shows dev usage.
   None of these read business data; they read metadata and logs.
   ===================================================================== */


/* =====================================================================
   PART A - DATABRICKS / UNITY CATALOG
   Needs: system schemas access, query, lakeflow enabled (account admin)
          and SELECT on them (metastore admin grant).
   Check first:  SHOW SCHEMAS IN system;
   ===================================================================== */

-- A1. Who CAN read: table, schema and catalog grants
--     (information_schema only shows rows the caller is allowed to see;
--      run as catalog owner / metastore admin for the full list)
SELECT 'TABLE'  AS level, grantee, table_schema, table_name, privilege_type, inherited_from
FROM   system.information_schema.table_privileges
WHERE  table_catalog = '<uc_catalog>' AND table_schema = 'fx_spectrum'
UNION ALL
SELECT 'SCHEMA', grantee, schema_name, NULL, privilege_type, inherited_from
FROM   system.information_schema.schema_privileges
WHERE  catalog_name = '<uc_catalog>' AND schema_name = 'fx_spectrum'
UNION ALL
SELECT 'CATALOG', grantee, NULL, NULL, privilege_type, inherited_from
FROM   system.information_schema.catalog_privileges
WHERE  catalog_name = '<uc_catalog>';
-- Grantees are usually groups. Ask a workspace/account admin to export
-- members of each group that appears here.


-- A2. Who DOES read: table lineage, last 12 months
--     One row per reading entity (job, notebook, pipeline, query, dashboard)
WITH jobs AS (
  SELECT workspace_id, job_id, name AS job_name, creator_id, run_as
  FROM   system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1
)
SELECT l.source_table_name,
       l.entity_type,                    -- JOB, NOTEBOOK, PIPELINE, DBSQL_QUERY, DASHBOARD..., NULL = ad hoc
       l.entity_id,
       j.job_name, j.run_as, j.creator_id,
       l.created_by,                     -- user / service principal that ran it
       l.target_table_full_name,         -- what it writes (NULL = read only, e.g. export or BI)
       l.workspace_id,
       MIN(l.event_date)                 AS first_seen,
       MAX(l.event_date)                 AS last_seen,
       COUNT(DISTINCT l.event_date)      AS active_days   -- ~1/month = monthly job (Sage)
FROM   system.access.table_lineage l
LEFT JOIN jobs j
       ON l.entity_type = 'JOB' AND j.job_id = l.entity_id AND j.workspace_id = l.workspace_id
WHERE  l.source_table_catalog = '<uc_catalog>'
  AND  l.source_table_schema  = 'fx_spectrum'
  AND  l.event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL
ORDER BY l.source_table_name, last_seen DESC;


-- A3. Column-level: who reads the columns that change or drop
--     Fill the IN list from the impact matrix (entity_type, address, ...)
SELECT source_table_name, source_column_name,
       target_table_full_name, target_column_name,
       entity_type, entity_id, created_by,
       MAX(event_date) AS last_seen
FROM   system.access.column_lineage
WHERE  source_table_catalog = '<uc_catalog>'
  AND  source_table_schema  = 'fx_spectrum'
  AND  source_column_name IN ('entity_type', 'address')   -- extend
  AND  event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL;
-- Note: the Spectrum field is called entity_type and so is a lineage
-- column. Here source_column_name = 'entity_type' means the Spectrum field.


-- A4. Second hop: who reads the tables built FROM fx_spectrum
--     (the 15 extracts and anything else written from Spectrum)
WITH hop1 AS (
  SELECT DISTINCT target_table_full_name AS t
  FROM   system.access.table_lineage
  WHERE  source_table_catalog = '<uc_catalog>'
    AND  source_table_schema  = 'fx_spectrum'
    AND  target_table_full_name IS NOT NULL
    AND  event_date >= current_date() - INTERVAL 365 DAYS
)
SELECT l.source_table_full_name AS spectrum_derived_table,
       l.entity_type, l.entity_id, l.created_by,
       l.target_table_full_name, l.target_type,
       MAX(l.event_date) AS last_seen
FROM   system.access.table_lineage l
JOIN   hop1 h ON h.t = l.source_table_full_name
WHERE  l.event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL;


-- A5. BI tools, JDBC/ODBC clients, ad hoc SQL (SQL warehouses + serverless)
--     Catches Power BI, Excel, Tableau, Airflow via JDBC, etc.
--     Misses queries that don't name the schema in the text (USE schema).
SELECT executed_by,
       client_application,
       compute.warehouse_id,
       COUNT(*)            AS queries,
       MIN(start_time)     AS first_seen,
       MAX(start_time)     AS last_seen
FROM   system.query.history
WHERE  statement_text ILIKE '%fx_spectrum%'
  AND  start_time >= current_timestamp() - INTERVAL 180 DAYS
GROUP BY ALL
ORDER BY queries DESC;


-- A6. Audit log: identities that resolved the tables (any compute type)
SELECT user_identity.email          AS identity,
       request_params.full_name_arg AS table_name,
       user_agent,
       source_ip_address,
       COUNT(*)                     AS events,
       MAX(event_date)              AS last_seen
FROM   system.access.audit
WHERE  service_name = 'unityCatalog'
  AND  action_name  = 'getTable'
  AND  request_params.full_name_arg LIKE '<uc_catalog>.fx_spectrum.%'
  AND  event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL
ORDER BY events DESC;


-- A7. Views that wrap the Spectrum tables (consumers may read the view)
SELECT table_catalog, table_schema, table_name
FROM   system.information_schema.views
WHERE  view_definition ILIKE '%fx_spectrum%';


-- A8. Delta Sharing (data leaving the platform)
-- SHOW SHARES;
-- SHOW ALL IN SHARE <share_name>;    -- for each share; look for fx_spectrum objects

-- Not visible in Unity Catalog lineage:
--   * reads through hive_metastore or direct abfss:// paths
--     -> Azure Storage diagnostic logs on the storage account
--   * code that exists but hasn't run in the window
--     -> text search of repos (notebooks, ADF JSON, Airflow DAGs) for
--        'fx_spectrum' and each table name


/* =====================================================================
   PART B - ON-PREM SQL SERVER
   Most of this needs VIEW ANY DEFINITION and VIEW SERVER STATE.
   B8/B9 (audit) need a DBA and normally a change ticket.
   ===================================================================== */

USE [<SpectrumDB>];
GO

-- B0. The tables in scope (fill with the 17 Spectrum tables)
DROP TABLE IF EXISTS #spectrum_tables;
CREATE TABLE #spectrum_tables (table_name sysname PRIMARY KEY);
INSERT INTO #spectrum_tables VALUES ('account_entry'), ('account_entry_detail'), ('cash_flow'); -- extend


-- B1. Who CAN read: database users, their logins and role membership
SELECT dp.name            AS db_user,
       dp.type_desc       AS user_type,      -- WINDOWS_GROUP needs expanding (B3)
       sp.name            AS login_name,
       sp.is_disabled,
       r.name             AS db_role
FROM   sys.database_principals dp
LEFT JOIN sys.server_principals    sp ON sp.sid = dp.sid
LEFT JOIN sys.database_role_members rm ON rm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals  r  ON r.principal_id = rm.role_principal_id
WHERE  dp.type <> 'R'
  AND  dp.name NOT IN ('sys', 'INFORMATION_SCHEMA')
ORDER BY dp.name;
-- If 'guest' has CONNECT, anyone with a login can read whatever public can.


-- B2. Explicit grants at database, schema, object and column level
SELECT pr.name        AS grantee,
       pr.type_desc   AS grantee_type,
       pe.state_desc,                       -- GRANT / DENY
       pe.permission_name,
       pe.class_desc,
       CASE pe.class
            WHEN 0 THEN '(whole database)'
            WHEN 3 THEN SCHEMA_NAME(pe.major_id) + '.*'
            WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id)
       END            AS securable,
       CASE WHEN pe.class = 1 AND pe.minor_id > 0
            THEN COL_NAME(pe.major_id, pe.minor_id) END AS column_name
FROM   sys.database_permissions pe
JOIN   sys.database_principals  pr ON pr.principal_id = pe.grantee_principal_id
WHERE  pe.permission_name IN ('SELECT', 'EXECUTE', 'CONTROL', 'VIEW DEFINITION', 'REFERENCES')
ORDER BY securable, grantee;
-- Members of db_datareader / db_owner read everything; B1 lists them.


-- B3. Server-level principals that can read every database
SELECT r.name AS server_role, m.name AS member, m.type_desc
FROM   sys.server_role_members srm
JOIN   sys.server_principals r ON r.principal_id = srm.role_principal_id
JOIN   sys.server_principals m ON m.principal_id = srm.member_principal_id
WHERE  r.name = 'sysadmin';

SELECT p.name, p.type_desc, sp.permission_name, sp.state_desc
FROM   sys.server_permissions sp
JOIN   sys.server_principals p ON p.principal_id = sp.grantee_principal_id
WHERE  sp.permission_name IN ('CONTROL SERVER', 'SELECT ALL USER SECURABLES', 'IMPERSONATE ANY LOGIN');

-- Expand each Windows group from B1/B3 to people:
-- EXEC xp_logininfo 'DOMAIN\GroupName', 'members';
-- (or Get-ADGroupMember -Recursive in PowerShell)


-- B4. Code inside SQL Server that references the tables
--     Run in EVERY database on the instance (cross-database references)
SELECT DB_NAME()                                            AS referencing_db,
       OBJECT_SCHEMA_NAME(d.referencing_id) + '.' + OBJECT_NAME(d.referencing_id) AS referencing_object,
       o.type_desc,
       d.referenced_server_name,                             -- linked-server reference
       d.referenced_database_name,
       d.referenced_schema_name + '.' + d.referenced_entity_name AS referenced_table
FROM   sys.sql_expression_dependencies d
JOIN   sys.objects o ON o.object_id = d.referencing_id
WHERE  d.referenced_entity_name IN (SELECT table_name FROM #spectrum_tables)
  AND (d.referenced_database_name = '<SpectrumDB>'
       OR (d.referenced_database_name IS NULL AND DB_NAME() = '<SpectrumDB>'));

-- Dynamic SQL is not tracked as a dependency; search the module text too
SELECT OBJECT_SCHEMA_NAME(m.object_id) + '.' + OBJECT_NAME(m.object_id) AS module, t.table_name
FROM   sys.sql_modules m
JOIN   #spectrum_tables t ON m.definition LIKE '%' + t.table_name + '%';

-- Synonyms pointing at Spectrum (any database)
SELECT name, base_object_name FROM sys.synonyms WHERE base_object_name LIKE '%<SpectrumDB>%';


-- B5. SQL Agent jobs that touch the database
SELECT j.name                       AS job_name,
       SUSER_SNAME(j.owner_sid)     AS job_owner,
       j.enabled,
       s.step_name, s.subsystem, s.database_name,
       sch.freq_type,               -- 4 daily, 8 weekly, 16/32 monthly
       LEFT(s.command, 4000)        AS command
FROM   msdb.dbo.sysjobs j
JOIN   msdb.dbo.sysjobsteps s           ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules js   ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules sch     ON sch.schedule_id = js.schedule_id
WHERE  s.database_name = '<SpectrumDB>'
   OR  s.command LIKE '%<SpectrumDB>%'
   OR  EXISTS (SELECT 1 FROM #spectrum_tables t WHERE s.command LIKE '%' + t.table_name + '%');


-- B6. SSIS packages whose connection managers point at the database
SELECT p.name AS project, op.object_name AS package_or_project, op.parameter_name,
       COALESCE(op.default_value, op.design_default_value) AS value
FROM   SSISDB.catalog.object_parameters op
JOIN   SSISDB.catalog.projects p ON p.project_id = op.project_id
WHERE  op.parameter_name LIKE '%ConnectionString%'
  AND  CAST(COALESCE(op.default_value, op.design_default_value) AS nvarchar(4000)) LIKE '%<SpectrumDB>%';


-- B7. SSRS reports built on the database, and who runs them
SELECT c.Path, c.Name,
       CONVERT(xml, CONVERT(varbinary(max), c.Content)) AS rdl   -- search for <SpectrumDB>/table names
FROM   ReportServer.dbo.Catalog c
WHERE  c.Type = 2;   -- 2 = report

SELECT ItemPath, UserName, COUNT(*) AS runs, MAX(TimeStart) AS last_run
FROM   ReportServer.dbo.ExecutionLog3
GROUP BY ItemPath, UserName;


-- B8. Which tables are read at all, and when last (since last restart)
SELECT OBJECT_SCHEMA_NAME(s.object_id) + '.' + OBJECT_NAME(s.object_id) AS table_name,
       SUM(s.user_seeks + s.user_scans + s.user_lookups)                AS reads,
       MAX(v.last_read)                                                  AS last_read,
       (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)            AS counters_since
FROM   sys.dm_db_index_usage_stats s
CROSS APPLY (VALUES (s.last_user_seek), (s.last_user_scan), (s.last_user_lookup)) v(last_read)
WHERE  s.database_id = DB_ID()
GROUP BY s.object_id;


-- B9. Query Store (if enabled): which queries hit the tables. No user info.
SELECT qt.query_sql_text, MAX(rs.last_execution_time) AS last_run, SUM(rs.count_executions) AS runs
FROM   sys.query_store_query_text qt
JOIN   sys.query_store_query q        ON q.query_text_id = qt.query_text_id
JOIN   sys.query_store_plan p         ON p.query_id = q.query_id
JOIN   sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
WHERE  EXISTS (SELECT 1 FROM #spectrum_tables t WHERE qt.query_sql_text LIKE '%' + t.table_name + '%')
GROUP BY qt.query_sql_text;


-- B10. Who DOES read: SQL Server Audit (DBA creates; production change)
--      Start now so the window covers Nov 30 month-end and Dec 31 year-end.
/*
USE master;
CREATE SERVER AUDIT Spectrum_Consumer_Audit
  TO FILE (FILEPATH = '<AuditPath>', MAXSIZE = 1 GB, MAX_ROLLOVER_FILES = 50)
  WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
ALTER SERVER AUDIT Spectrum_Consumer_Audit WITH (STATE = ON);

USE [<SpectrumDB>];
CREATE DATABASE AUDIT SPECIFICATION Spectrum_Read_Audit
  FOR SERVER AUDIT Spectrum_Consumer_Audit
  ADD (SELECT  ON DATABASE::[<SpectrumDB>] BY public),
  ADD (EXECUTE ON DATABASE::[<SpectrumDB>] BY public)
  WITH (STATE = ON);
*/

-- Read the audit (needs CONTROL SERVER; VIEW SERVER SECURITY AUDIT on SQL 2022)
-- application_name / client_ip / host_name exist on newer versions only.
/*
SELECT server_principal_name, session_server_principal_name,
       application_name, client_ip, host_name,
       schema_name + '.' + object_name AS table_name,
       COUNT(*) AS events, MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM   sys.fn_get_audit_file('<AuditPath>\Spectrum_Consumer_Audit*.sqlaudit', DEFAULT, DEFAULT)
GROUP BY server_principal_name, session_server_principal_name,
         application_name, client_ip, host_name, schema_name + '.' + object_name
ORDER BY events DESC;
*/

-- Fallback if the audit change is refused: an Agent job every 5 minutes
-- that appends sys.dm_exec_sessions rows (login_name, host_name,
-- program_name, database_id = DB_ID('<SpectrumDB>')) to a log table.
-- Cheaper to approve, but misses short connections between samples.

-- Outside this instance: other SQL Servers may read Spectrum through a
-- linked server. The DBA checks sys.servers and B4 on those instances.
