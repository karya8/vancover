/* =====================================================================
   REQUEST FOR: SQL Server DBA (Spectrum on-prem instance)
   From: Kapil, BSA, FX Spectrum migration

   Why: the Spectrum database stops being fed / is retired at cutover.
   We need the full list of logins, jobs, reports and code that read it,
   so every consumer can be moved before then.

   What to run: PRODUCTION instance. Queries 1-9 read metadata and DMVs
   only, no business data. Query 10 is a SQL Server Audit and needs a
   change ticket.

   What to send back: one CSV per query, named Q1.csv, Q2.csv, ...
   with column headers. For Q4, run it in every database on the
   instance and add the database name. If a query errors (feature not
   installed: SSIS, SSRS, Query Store), note "N/A" and move on.

   Placeholders:  <SpectrumDB>  <AuditPath>
   ===================================================================== */

USE [<SpectrumDB>];
GO

-- Q0. Tables in scope (17 Spectrum tables; add the remaining names)
DROP TABLE IF EXISTS #spectrum_tables;
CREATE TABLE #spectrum_tables (table_name sysname PRIMARY KEY);
INSERT INTO #spectrum_tables VALUES ('account_entry'), ('account_entry_detail'), ('cash_flow');


-- Q1. Database users, their logins, and role membership
SELECT dp.name AS db_user, dp.type_desc AS user_type, sp.name AS login_name,
       sp.is_disabled, r.name AS db_role
FROM   sys.database_principals dp
LEFT JOIN sys.server_principals     sp ON sp.sid = dp.sid
LEFT JOIN sys.database_role_members rm ON rm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals   r  ON r.principal_id = rm.role_principal_id
WHERE  dp.type <> 'R' AND dp.name NOT IN ('sys', 'INFORMATION_SCHEMA')
ORDER BY dp.name;


-- Q2. Explicit grants (database, schema, object, column level)
SELECT pr.name AS grantee, pr.type_desc AS grantee_type, pe.state_desc,
       pe.permission_name, pe.class_desc,
       CASE pe.class WHEN 0 THEN '(whole database)'
                     WHEN 3 THEN SCHEMA_NAME(pe.major_id) + '.*'
                     WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id) END AS securable,
       CASE WHEN pe.class = 1 AND pe.minor_id > 0 THEN COL_NAME(pe.major_id, pe.minor_id) END AS column_name
FROM   sys.database_permissions pe
JOIN   sys.database_principals  pr ON pr.principal_id = pe.grantee_principal_id
WHERE  pe.permission_name IN ('SELECT', 'EXECUTE', 'CONTROL', 'VIEW DEFINITION', 'REFERENCES')
ORDER BY securable, grantee;


-- Q3. Server-level principals that can read every database
SELECT 'sysadmin' AS via, m.name AS principal, m.type_desc
FROM   sys.server_role_members srm
JOIN   sys.server_principals r ON r.principal_id = srm.role_principal_id
JOIN   sys.server_principals m ON m.principal_id = srm.member_principal_id
WHERE  r.name = 'sysadmin'
UNION ALL
SELECT sp.permission_name, p.name, p.type_desc
FROM   sys.server_permissions sp
JOIN   sys.server_principals p ON p.principal_id = sp.grantee_principal_id
WHERE  sp.permission_name IN ('CONTROL SERVER', 'SELECT ALL USER SECURABLES', 'IMPERSONATE ANY LOGIN')
  AND  sp.state_desc IN ('GRANT', 'GRANT_WITH_GRANT_OPTION');

-- Q3b. For every WINDOWS_GROUP in Q1/Q3, list members:
-- EXEC xp_logininfo 'DOMAIN\GroupName', 'members';


-- Q4. Views, procs, functions that reference the tables
--     RUN IN EVERY DATABASE ON THE INSTANCE (re-create #spectrum_tables in each)
SELECT DB_NAME() AS referencing_db,
       OBJECT_SCHEMA_NAME(d.referencing_id) + '.' + OBJECT_NAME(d.referencing_id) AS referencing_object,
       o.type_desc, d.referenced_server_name, d.referenced_database_name,
       d.referenced_schema_name + '.' + d.referenced_entity_name AS referenced_table
FROM   sys.sql_expression_dependencies d
JOIN   sys.objects o ON o.object_id = d.referencing_id
WHERE  d.referenced_entity_name IN (SELECT table_name FROM #spectrum_tables)
  AND (d.referenced_database_name = '<SpectrumDB>'
       OR (d.referenced_database_name IS NULL AND DB_NAME() = '<SpectrumDB>'))
UNION
SELECT DB_NAME(), OBJECT_SCHEMA_NAME(m.object_id) + '.' + OBJECT_NAME(m.object_id),
       'TEXT MATCH (dynamic SQL)', NULL, NULL, t.table_name
FROM   sys.sql_modules m
JOIN   #spectrum_tables t ON m.definition LIKE '%' + t.table_name + '%';

-- Q4b. Synonyms (every database)
SELECT DB_NAME() AS db, name, base_object_name
FROM   sys.synonyms WHERE base_object_name LIKE '%<SpectrumDB>%';


-- Q5. SQL Agent jobs touching the database, with owner and schedule
SELECT j.name AS job_name, SUSER_SNAME(j.owner_sid) AS job_owner, j.enabled,
       s.step_name, s.subsystem, s.database_name,
       sch.freq_type,                -- 4 daily, 8 weekly, 16/32 monthly
       LEFT(s.command, 4000) AS command
FROM   msdb.dbo.sysjobs j
JOIN   msdb.dbo.sysjobsteps s          ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules js  ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules sch    ON sch.schedule_id = js.schedule_id
WHERE  s.database_name = '<SpectrumDB>'
   OR  s.command LIKE '%<SpectrumDB>%'
   OR  EXISTS (SELECT 1 FROM #spectrum_tables t WHERE s.command LIKE '%' + t.table_name + '%');


-- Q6. SSIS packages connecting to the database (skip if SSISDB absent)
SELECT p.name AS project, op.object_name, op.parameter_name,
       CAST(COALESCE(op.default_value, op.design_default_value) AS nvarchar(4000)) AS value
FROM   SSISDB.catalog.object_parameters op
JOIN   SSISDB.catalog.projects p ON p.project_id = op.project_id
WHERE  op.parameter_name LIKE '%ConnectionString%'
  AND  CAST(COALESCE(op.default_value, op.design_default_value) AS nvarchar(4000)) LIKE '%<SpectrumDB>%';


-- Q7. SSRS reports on the database and who runs them (skip if no SSRS)
SELECT c.Path, c.Name
FROM   ReportServer.dbo.Catalog c
WHERE  c.Type = 2
  AND  CONVERT(nvarchar(max), CONVERT(xml, CONVERT(varbinary(max), c.Content))) LIKE '%<SpectrumDB>%';

SELECT ItemPath, UserName, COUNT(*) AS runs, MAX(TimeStart) AS last_run
FROM   ReportServer.dbo.ExecutionLog3
GROUP BY ItemPath, UserName;


-- Q8. Which tables are read, and when last (since last restart)
SELECT OBJECT_SCHEMA_NAME(s.object_id) + '.' + OBJECT_NAME(s.object_id) AS table_name,
       SUM(s.user_seeks + s.user_scans + s.user_lookups) AS reads,
       MAX(v.last_read) AS last_read,
       (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS counters_since
FROM   sys.dm_db_index_usage_stats s
CROSS APPLY (VALUES (s.last_user_seek), (s.last_user_scan), (s.last_user_lookup)) v(last_read)
WHERE  s.database_id = DB_ID()
GROUP BY s.object_id;

-- Q8b. Who is connected right now (one snapshot; repeat a few times a day if Q10 is refused)
SELECT login_name, original_login_name, host_name, program_name,
       client_interface_name, MAX(last_request_start_time) AS last_request
FROM   sys.dm_exec_sessions
WHERE  database_id = DB_ID('<SpectrumDB>') AND is_user_process = 1
GROUP BY login_name, original_login_name, host_name, program_name, client_interface_name;


-- Q9. Query Store text matches (skip if Query Store is off)
SELECT LEFT(qt.query_sql_text, 4000) AS query_text,
       MAX(rs.last_execution_time) AS last_run, SUM(rs.count_executions) AS runs
FROM   sys.query_store_query_text qt
JOIN   sys.query_store_query q          ON q.query_text_id = qt.query_text_id
JOIN   sys.query_store_plan p           ON p.query_id = q.query_id
JOIN   sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
WHERE  EXISTS (SELECT 1 FROM #spectrum_tables t WHERE qt.query_sql_text LIKE '%' + t.table_name + '%')
GROUP BY LEFT(qt.query_sql_text, 4000);


/* Q10. SQL Server Audit - CHANGE TICKET REQUIRED
   Needed live before Nov 30 so it covers month-end (monthly Sage jobs)
   and Dec 31 year-end. Leave running until cutover.
   Volume should be small: one event per SELECT statement on this DB.

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

-- Weekly summary to send back (drop application_name/client_ip/host_name
-- if the version doesn't have them):
SELECT server_principal_name, session_server_principal_name,
       application_name, client_ip, host_name,
       schema_name + '.' + object_name AS table_name,
       COUNT(*) AS events, MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
FROM   sys.fn_get_audit_file('<AuditPath>\Spectrum_Consumer_Audit*.sqlaudit', DEFAULT, DEFAULT)
GROUP BY server_principal_name, session_server_principal_name,
         application_name, client_ip, host_name, schema_name + '.' + object_name;
*/


/* Q11. Other instances
   On every other SQL Server instance in the estate, list linked servers
   that point at the Spectrum host, and run Q4 there:
   SELECT name, data_source, provider FROM sys.servers WHERE is_linked = 1;
*/
