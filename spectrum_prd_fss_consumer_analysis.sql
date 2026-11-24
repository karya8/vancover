/* =====================================================================
   spectrum_prd_fss - consumer analysis
   SQL Server 2008 Standard
   Prepared by: Kapil, BSA - FX Spectrum migration

   Purpose
   For the FX Spectrum migration we need a full list of what reads
   spectrum_prd_fss: logins, Agent jobs, SSIS packages, SSRS reports,
   and objects in other databases that reference it. Scope is every
   user table and view in the database.

   How to run
   - Production instance.
   - Run Q0 first. Q1 to Q9 use the object list it builds, so keep the
     same session/query window open.
   - Q1 to Q9 are read-only. They query system views and DMVs only.
     No business data is selected.
   - Q10 is a server-side trace and needs a change ticket. We need it
     running before the Nov 30 month-end and left on until cutover.
     Please let me know your change lead time.
   - Replace <TracePath> with a folder for the trace files and <UtilDB>
     with the database you use for DBA tooling. Please don't create
     anything in spectrum_prd_fss.

   What to send back
   - One CSV per query (Q0.csv, Q1.csv, ...) with column headers.
   - If something doesn't apply on this server (no SSIS or SSRS), mark
     it N/A.
   - Q10: the 10.4 summary output once a week.

   Text comparisons use COLLATE SQL_Latin1_General_CP1_CI_AS because
   spectrum_prd_fss and the system databases have different collations.
   ===================================================================== */


-- Q00. Version, edition and database collation
SELECT SERVERPROPERTY('ProductVersion')                         AS version,
       SERVERPROPERTY('Edition')                                AS edition,
       SERVERPROPERTY('ProductLevel')                           AS service_pack,
       SERVERPROPERTY('Collation')                              AS server_collation,
       DATABASEPROPERTYEX('spectrum_prd_fss', 'Collation')      AS spectrum_collation;


USE [spectrum_prd_fss];
GO

-- Q0. All user tables and views in spectrum_prd_fss
IF OBJECT_ID('tempdb..#spectrum_objects') IS NOT NULL DROP TABLE #spectrum_objects;
CREATE TABLE #spectrum_objects (
    schema_name  sysname COLLATE SQL_Latin1_General_CP1_CI_AS,
    object_name  sysname COLLATE SQL_Latin1_General_CP1_CI_AS,
    object_type  varchar(10),
    create_date  datetime,
    modify_date  datetime,
    PRIMARY KEY (schema_name, object_name));

INSERT INTO #spectrum_objects
SELECT s.name, o.name,
       CASE o.type WHEN 'U' THEN 'TABLE' ELSE 'VIEW' END,
       o.create_date, o.modify_date
FROM   sys.objects o
JOIN   sys.schemas s ON s.schema_id = o.schema_id
WHERE  o.type IN ('U', 'V')
  AND  o.is_ms_shipped = 0;

SELECT * FROM #spectrum_objects ORDER BY object_type, schema_name, object_name;


-- Q1. Database users, their logins, and role membership
SELECT dp.name AS db_user, dp.type_desc AS user_type, sp.name AS login_name,
       sp.is_disabled, r.name AS db_role
FROM   sys.database_principals dp
LEFT JOIN sys.server_principals     sp ON sp.sid = dp.sid
LEFT JOIN sys.database_role_members rm ON rm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals   r  ON r.principal_id = rm.role_principal_id
WHERE  dp.type <> 'R' AND dp.name NOT IN ('sys', 'INFORMATION_SCHEMA')
ORDER BY dp.name;


-- Q2. Explicit permissions (database, schema, object and column level)
SELECT pr.name AS grantee, pr.type_desc AS grantee_type, pe.state_desc,
       pe.permission_name, pe.class_desc,
       CASE pe.class WHEN 0 THEN '(database)'
                     WHEN 3 THEN SCHEMA_NAME(pe.major_id) + '.*'
                     WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id) END AS securable,
       CASE WHEN pe.class = 1 AND pe.minor_id > 0 THEN COL_NAME(pe.major_id, pe.minor_id) END AS column_name
FROM   sys.database_permissions pe
JOIN   sys.database_principals  pr ON pr.principal_id = pe.grantee_principal_id
WHERE  pe.permission_name IN ('SELECT', 'EXECUTE', 'CONTROL', 'VIEW DEFINITION', 'REFERENCES')
ORDER BY securable, grantee;


-- Q3. Server-level logins that can read every database
SELECT 'sysadmin' AS via, m.name AS principal, m.type_desc
FROM   sys.server_role_members srm
JOIN   sys.server_principals r ON r.principal_id = srm.role_principal_id
JOIN   sys.server_principals m ON m.principal_id = srm.member_principal_id
WHERE  r.name = 'sysadmin'
UNION ALL
SELECT sp.permission_name, p.name, p.type_desc
FROM   sys.server_permissions sp
JOIN   sys.server_principals p ON p.principal_id = sp.grantee_principal_id
WHERE  sp.permission_name IN ('CONTROL SERVER', 'IMPERSONATE')
  AND  sp.state_desc IN ('GRANT', 'GRANT_WITH_GRANT_OPTION');

-- Q3b. Members of each Windows group listed in Q1 or Q3:
-- EXEC xp_logininfo 'DOMAIN\GroupName', 'members';


-- Q4. Objects in any database on the instance that reference
--     spectrum_prd_fss (dependencies, text matches in code, synonyms).
--     Loops through all online user databases; one result set.
IF OBJECT_ID('tempdb..#q4') IS NOT NULL DROP TABLE #q4;
CREATE TABLE #q4 (
    referencing_db      sysname,
    referencing_object  nvarchar(520),
    object_type         nvarchar(60),
    referenced_server   sysname NULL,
    referenced_db       sysname NULL,
    referenced_object   nvarchar(520),
    match_type          varchar(20));

DECLARE @db sysname, @sql nvarchar(max);
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE';
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE ' + QUOTENAME(@db) + N';

INSERT INTO #q4
SELECT DB_NAME(),
       OBJECT_SCHEMA_NAME(d.referencing_id) + ''.'' + OBJECT_NAME(d.referencing_id),
       o.type_desc, d.referenced_server_name, d.referenced_database_name,
       ISNULL(d.referenced_schema_name + ''.'', '''') + d.referenced_entity_name,
       ''DEPENDENCY''
FROM   sys.sql_expression_dependencies d
JOIN   sys.objects o ON o.object_id = d.referencing_id
WHERE  d.referenced_entity_name COLLATE SQL_Latin1_General_CP1_CI_AS IN (SELECT object_name FROM #spectrum_objects)
  AND (d.referenced_database_name COLLATE SQL_Latin1_General_CP1_CI_AS = ''spectrum_prd_fss''
       OR (d.referenced_database_name IS NULL AND DB_NAME() = ''spectrum_prd_fss''));

INSERT INTO #q4
SELECT DB_NAME(),
       OBJECT_SCHEMA_NAME(m.object_id) + ''.'' + OBJECT_NAME(m.object_id),
       o.type_desc, NULL, NULL, t.object_name, ''TEXT MATCH''
FROM   sys.sql_modules m
JOIN   sys.objects o ON o.object_id = m.object_id
JOIN   #spectrum_objects t
       ON m.definition COLLATE SQL_Latin1_General_CP1_CI_AS LIKE ''%'' + t.object_name + ''%''
WHERE  OBJECT_NAME(m.object_id) COLLATE SQL_Latin1_General_CP1_CI_AS <> t.object_name;

INSERT INTO #q4
SELECT DB_NAME(), SCHEMA_NAME(s.schema_id) + ''.'' + s.name, ''SYNONYM'',
       NULL, NULL, s.base_object_name, ''SYNONYM''
FROM   sys.synonyms s
WHERE  s.base_object_name COLLATE SQL_Latin1_General_CP1_CI_AS LIKE ''%spectrum_prd_fss%'';';

    EXEC sp_executesql @sql;
    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

SELECT DISTINCT * FROM #q4 ORDER BY referencing_db, referencing_object, referenced_object;


-- Q5. SQL Agent jobs that touch spectrum_prd_fss
SELECT j.name AS job_name, SUSER_SNAME(j.owner_sid) AS job_owner, j.enabled,
       s.step_id, s.step_name, s.subsystem, s.database_name,
       sch.freq_type,                -- 4 daily, 8 weekly, 16/32 monthly, 64 at Agent start
       LEFT(s.command, 4000) AS command
FROM   msdb.dbo.sysjobs j
JOIN   msdb.dbo.sysjobsteps s          ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules js  ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules sch    ON sch.schedule_id = js.schedule_id
CROSS APPLY (SELECT s.command COLLATE SQL_Latin1_General_CP1_CI_AS AS cmd) x
WHERE  s.database_name COLLATE SQL_Latin1_General_CP1_CI_AS = 'spectrum_prd_fss'
   OR  x.cmd LIKE '%spectrum_prd_fss%'
   OR  EXISTS (SELECT 1 FROM #spectrum_objects t WHERE x.cmd LIKE '%' + t.object_name + '%')
ORDER BY j.name, s.step_id;


-- Q6. SSIS packages stored in msdb that reference the database or its objects
SELECT f.foldername, p.name AS package_name, p.createdate
FROM   msdb.dbo.sysssispackages p
LEFT JOIN msdb.dbo.sysssispackagefolders f ON f.folderid = p.folderid
CROSS APPLY (SELECT CAST(CAST(p.packagedata AS varbinary(max)) AS varchar(max))
                    COLLATE SQL_Latin1_General_CP1_CI_AS AS pkg) x
WHERE  x.pkg LIKE '%spectrum_prd_fss%'
   OR  EXISTS (SELECT 1 FROM #spectrum_objects t WHERE x.pkg LIKE '%' + t.object_name + '%');
-- File-system packages are not in msdb. Please also search the package
-- folders, e.g.:  findstr /s /i /m "spectrum_prd_fss" D:\SSIS\*.dtsx


-- Q7. SSRS (skip if SSRS is not on this server)

-- Q7a. Reports whose query or connection mentions the database or its objects
SELECT c.Path, c.Name
FROM   ReportServer.dbo.Catalog c
CROSS APPLY (SELECT CONVERT(nvarchar(max), CONVERT(xml, CONVERT(varbinary(max), c.Content)))
                    COLLATE SQL_Latin1_General_CP1_CI_AS AS rdl) x
WHERE  c.Type = 2
  AND (x.rdl LIKE '%spectrum_prd_fss%'
       OR EXISTS (SELECT 1 FROM #spectrum_objects t WHERE x.rdl LIKE '%' + t.object_name + '%'));

-- Q7b. Shared data sources and the reports using them. Please mark which
--      data sources point at spectrum_prd_fss.
SELECT ds.Path AS shared_data_source, r.Path AS report
FROM   ReportServer.dbo.DataSource d
JOIN   ReportServer.dbo.Catalog r  ON r.ItemID = d.ItemID
JOIN   ReportServer.dbo.Catalog ds ON ds.ItemID = d.Link
WHERE  ds.Type = 5
ORDER BY ds.Path, r.Path;

-- Q7c. Who ran which report (ExecutionLog keeps 60 days by default)
SELECT c.Path, e.UserName, COUNT(*) AS runs, MAX(e.TimeStart) AS last_run
FROM   ReportServer.dbo.ExecutionLog e
JOIN   ReportServer.dbo.Catalog c ON c.ItemID = e.ReportID
GROUP BY c.Path, e.UserName
ORDER BY c.Path, runs DESC;


-- Q8. Read activity per table since the last service restart
--     (tables with 0 reads are listed too)
USE [spectrum_prd_fss];
SELECT so.schema_name + '.' + so.object_name AS table_name,
       ISNULL(SUM(u.reads), 0)  AS reads,
       MAX(u.last_read)         AS last_read,
       (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS counters_since
FROM   #spectrum_objects so
LEFT JOIN (
    SELECT s.object_id,
           s.user_seeks + s.user_scans + s.user_lookups AS reads,
           (SELECT MAX(v) FROM (VALUES (s.last_user_seek), (s.last_user_scan), (s.last_user_lookup)) x(v)) AS last_read
    FROM   sys.dm_db_index_usage_stats s
    WHERE  s.database_id = DB_ID()
) u ON u.object_id = OBJECT_ID(QUOTENAME(so.schema_name) + '.' + QUOTENAME(so.object_name))
WHERE  so.object_type = 'TABLE'
GROUP BY so.schema_name, so.object_name
ORDER BY reads DESC;


-- Q8b. Sessions connected to spectrum_prd_fss at the time of running
SELECT loginame, nt_domain, nt_username, hostname, program_name,
       COUNT(*) AS sessions, MAX(last_batch) AS last_batch
FROM   sys.sysprocesses
WHERE  dbid = DB_ID('spectrum_prd_fss') AND spid > 50
GROUP BY loginame, nt_domain, nt_username, hostname, program_name;


-- Q9. Cached query text that references spectrum_prd_fss objects
SELECT TOP 500 DB_NAME(st.dbid) AS db, qs.execution_count, qs.last_execution_time,
       LEFT(st.text, 4000) AS query_text
FROM   sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY (SELECT st.text COLLATE SQL_Latin1_General_CP1_CI_AS AS txt) x
WHERE  x.txt LIKE '%spectrum_prd_fss%'
   OR  EXISTS (SELECT 1 FROM #spectrum_objects t WHERE x.txt LIKE '%' + t.object_name + '%')
ORDER BY qs.last_execution_time DESC;


/* =====================================================================
   Q10. Server-side trace - CHANGE TICKET REQUIRED
   Start before Nov 30, keep running until cutover.

   Two traces (RPC:Completed and SQL:BatchCompleted):
     ctx - statements run with spectrum_prd_fss as the current database
     xdb - statements from other databases that name spectrum_prd_fss
   Files roll over at 256 MB (40 and 20 files max).
   Traces stop on a service restart, so 10.2 restarts them at Agent start.
   ===================================================================== */

-- 10.1 Start procedure (does nothing if the traces are already running)
--      Run the CREATE PROCEDURE in <UtilDB> as its own batch, then the
--      EXEC and SELECT at the end.
/*
CREATE PROCEDURE dbo.usp_start_spectrum_traces
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM sys.traces WHERE path LIKE N'%Spectrum[_]ctx[_]%') RETURN;

    DECLARE @t1 int, @t2 int, @rc int, @on bit, @maxsize bigint, @dbid int,
            @stamp nvarchar(20), @f1 nvarchar(245), @f2 nvarchar(245), @c int, @col int;
    SET @on = 1;
    SET @maxsize = 256;
    SET @dbid = DB_ID('spectrum_prd_fss');
    SET @stamp = REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(16), GETDATE(), 120), '-', ''), ':', ''), ' ', '_');
    SET @f1 = N'<TracePath>\Spectrum_ctx_' + @stamp;
    SET @f2 = N'<TracePath>\Spectrum_xdb_' + @stamp;

    EXEC @rc = sp_trace_create @t1 OUTPUT, 2, @f1, @maxsize, NULL, 40;
    IF @rc <> 0 BEGIN RAISERROR('ctx trace create failed: %d', 16, 1, @rc); RETURN; END
    EXEC @rc = sp_trace_create @t2 OUTPUT, 2, @f2, @maxsize, NULL, 20;
    IF @rc <> 0 BEGIN RAISERROR('xdb trace create failed: %d', 16, 1, @rc); RETURN; END

    -- Events: 10 RPC:Completed, 12 SQL:BatchCompleted
    -- Columns: 1 TextData, 3 DatabaseID, 6 NTUserName, 7 NTDomainName, 8 HostName,
    --          10 ApplicationName, 11 LoginName, 14 StartTime, 35 DatabaseName
    SET @c = 0;
    WHILE @c < 9
    BEGIN
        SET @c = @c + 1;
        SET @col = CASE @c WHEN 1 THEN 1  WHEN 2 THEN 3  WHEN 3 THEN 6
                           WHEN 4 THEN 7  WHEN 5 THEN 8  WHEN 6 THEN 10
                           WHEN 7 THEN 11 WHEN 8 THEN 14 ELSE 35 END;
        EXEC sp_trace_setevent @t1, 10, @col, @on;
        EXEC sp_trace_setevent @t1, 12, @col, @on;
        EXEC sp_trace_setevent @t2, 10, @col, @on;
        EXEC sp_trace_setevent @t2, 12, @col, @on;
    END;

    -- ctx: DatabaseID = spectrum_prd_fss
    EXEC sp_trace_setfilter @t1, 3, 0, 0, @dbid;
    -- xdb: TextData LIKE '%spectrum_prd_fss%' and DatabaseID <> spectrum_prd_fss
    EXEC sp_trace_setfilter @t2, 1, 0, 6, N'%spectrum_prd_fss%';
    EXEC sp_trace_setfilter @t2, 3, 0, 1, @dbid;

    EXEC sp_trace_setstatus @t1, 1;
    EXEC sp_trace_setstatus @t2, 1;
END;

-- then:
EXEC dbo.usp_start_spectrum_traces;
SELECT id, path, max_size, max_files, start_time FROM sys.traces;
*/

-- 10.2 SQL Agent job "Spectrum trace - start"
--      Step:     EXEC [<UtilDB>].dbo.usp_start_spectrum_traces;
--      Schedule: Start automatically when SQL Server Agent starts

-- 10.3 Please check the size of <TracePath> after the first day and
--      adjust file size/count if needed.

-- 10.4 Weekly summary. Run Q0 first in the same session.
/*
USE [<UtilDB>];
IF OBJECT_ID('dbo.spectrum_trace_load') IS NOT NULL DROP TABLE dbo.spectrum_trace_load;
CREATE TABLE dbo.spectrum_trace_load (
    trace_set nvarchar(260), LoginName nvarchar(256), NTDomainName nvarchar(256),
    NTUserName nvarchar(256), HostName nvarchar(256), ApplicationName nvarchar(256),
    DatabaseName nvarchar(256), StartTime datetime, txt nvarchar(max));

DECLARE @files TABLE (subdirectory nvarchar(260), depth int, isfile bit);
INSERT INTO @files EXEC master.sys.xp_dirtree N'<TracePath>', 1, 1;

-- First file of each trace set; fn_trace_gettable reads its rollover files too
DECLARE @todo TABLE (id int IDENTITY(1,1), file_name nvarchar(260));
INSERT INTO @todo (file_name)
SELECT subdirectory
FROM   @files
WHERE  isfile = 1
  AND  subdirectory LIKE N'Spectrum[_]___[_]________[_]____.trc';

DECLARE @i int, @n int, @f nvarchar(260), @p nvarchar(260);
SET @i = 1;
SELECT @n = COUNT(*) FROM @todo;

WHILE @i <= @n
BEGIN
    SELECT @f = file_name FROM @todo WHERE id = @i;
    SET @p = N'<TracePath>\' + @f;

    INSERT INTO dbo.spectrum_trace_load
    SELECT @f, LoginName, NTDomainName, NTUserName, HostName, ApplicationName,
           DatabaseName, StartTime, CAST(TextData AS nvarchar(max))
    FROM   fn_trace_gettable(@p, DEFAULT);

    SET @i = @i + 1;
END;

-- Check: rows loaded per trace set
SELECT trace_set, COUNT(*) AS rows_loaded FROM dbo.spectrum_trace_load GROUP BY trace_set;

SELECT l.LoginName, l.NTDomainName + '\' + l.NTUserName AS windows_user,
       l.HostName, l.ApplicationName, l.DatabaseName AS context_db,
       t.schema_name + '.' + t.object_name AS spectrum_object,
       COUNT(*) AS statements, MIN(l.StartTime) AS first_seen, MAX(l.StartTime) AS last_seen
FROM   dbo.spectrum_trace_load l
JOIN   #spectrum_objects t
       ON l.txt COLLATE SQL_Latin1_General_CP1_CI_AS LIKE '%' + t.object_name + '%'
GROUP BY l.LoginName, l.NTDomainName + '\' + l.NTUserName, l.HostName,
         l.ApplicationName, l.DatabaseName, t.schema_name + '.' + t.object_name
ORDER BY statements DESC;
*/

-- 10.5 At cutover: stop and close both traces (ids from sys.traces) and
--      disable the 10.2 job.
--      EXEC sp_trace_setstatus <id>, 0;  EXEC sp_trace_setstatus <id>, 2;


/* If the trace can't be approved: session sampler as an interim measure.
   Agent job every 5 minutes. Shows who connects, not which objects.

CREATE TABLE dbo.spectrum_session_log (
    sampled_at datetime, loginame nvarchar(128), nt_domain nvarchar(128),
    nt_username nvarchar(128), hostname nvarchar(128), program_name nvarchar(128),
    last_batch datetime);          -- in <UtilDB>

INSERT INTO dbo.spectrum_session_log
SELECT GETDATE(), loginame, nt_domain, nt_username, hostname, program_name, last_batch
FROM   sys.sysprocesses
WHERE  dbid = DB_ID('spectrum_prd_fss') AND spid > 50;
*/


/* Q11. Other SQL Server instances
   If other instances have linked servers pointing at this server,
   please run Q4 there as well:
   SELECT name, data_source, provider FROM sys.servers WHERE is_linked = 1;
*/
