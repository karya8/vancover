/* =====================================================================
   REQUEST FOR: SQL Server DBA (Spectrum on-prem instance)
   VERSION: SQL Server 2008 / 2008 R2, Standard edition
   From: Kapil, BSA, FX Spectrum migration

   Why: the Spectrum database stops being fed / is retired at cutover.
   We need the full list of logins, jobs, reports and code that read it,
   so every consumer can be moved before then.

   What to run: PRODUCTION instance. Q0-Q9 read metadata and DMVs only,
   no business data. Q10 (server-side trace) is a change and needs a
   ticket. It must be running before Nov 30 month-end.

   What to send back: one CSV per query (Q1.csv, Q2.csv, ...), with
   headers. Run Q4 in every user database on the instance. If a query
   errors because a feature isn't installed (SSIS, SSRS), note "N/A".

   Placeholders: <SpectrumDB>  <TracePath>  <UtilDB> (DBA utility database)
   ===================================================================== */

-- Q00. Version and edition
SELECT SERVERPROPERTY('ProductVersion') AS version,   -- 10.0.x = 2008, 10.50.x = 2008 R2
       SERVERPROPERTY('Edition')        AS edition,
       SERVERPROPERTY('ProductLevel')   AS service_pack;

USE [<SpectrumDB>];
GO

-- Q0. Tables in scope (17 Spectrum tables; add the remaining names)
IF OBJECT_ID('tempdb..#spectrum_tables') IS NOT NULL DROP TABLE #spectrum_tables;
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
WHERE  sp.permission_name IN ('CONTROL SERVER', 'IMPERSONATE')
  AND  sp.state_desc IN ('GRANT', 'GRANT_WITH_GRANT_OPTION');

-- Q3b. For every WINDOWS_GROUP in Q1/Q3, list members:
-- EXEC xp_logininfo 'DOMAIN\GroupName', 'members';


-- Q4. Views, procs, functions that reference the tables
--     RUN IN EVERY USER DATABASE (re-create #spectrum_tables in each)
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


-- Q6. SSIS packages stored in msdb (2008 has no SSISDB)
SELECT f.foldername, p.name AS package_name, p.createdate
FROM   msdb.dbo.sysssispackages p
LEFT JOIN msdb.dbo.sysssispackagefolders f ON f.folderid = p.folderid
WHERE  CAST(CAST(p.packagedata AS varbinary(max)) AS varchar(max)) LIKE '%<SpectrumDB>%';
-- Packages deployed to the file system are not in msdb. Search the SSIS
-- package folders for *.dtsx files containing <SpectrumDB>, e.g.
--   findstr /s /i /m "<SpectrumDB>" D:\SSIS\*.dtsx
-- Q5 also shows SSIS job steps with their /FILE or /SQL package path.


-- Q7. SSRS reports on the database and who runs them (skip if no SSRS)
SELECT c.Path, c.Name
FROM   ReportServer.dbo.Catalog c
WHERE  c.Type = 2
  AND  CONVERT(nvarchar(max), CONVERT(xml, CONVERT(varbinary(max), c.Content))) LIKE '%<SpectrumDB>%';

SELECT c.Path, e.UserName, COUNT(*) AS runs, MAX(e.TimeStart) AS last_run
FROM   ReportServer.dbo.ExecutionLog e
JOIN   ReportServer.dbo.Catalog c ON c.ItemID = e.ReportID
GROUP BY c.Path, e.UserName;
-- ExecutionLog keeps 60 days by default.


-- Q8. Which tables are read, and when last (since last restart)
SELECT OBJECT_SCHEMA_NAME(s.object_id) + '.' + OBJECT_NAME(s.object_id) AS table_name,
       SUM(s.user_seeks + s.user_scans + s.user_lookups) AS reads,
       MAX(v.last_read) AS last_read,
       (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS counters_since
FROM   sys.dm_db_index_usage_stats s
CROSS APPLY (VALUES (s.last_user_seek), (s.last_user_scan), (s.last_user_lookup)) v(last_read)
WHERE  s.database_id = DB_ID()
GROUP BY s.object_id;


-- Q8b. Who is connected to the database right now
--      (2008: sys.dm_exec_sessions has no database_id, so use sysprocesses)
SELECT loginame, nt_domain, nt_username, hostname, program_name,
       COUNT(*) AS sessions, MAX(last_batch) AS last_batch
FROM   sys.sysprocesses
WHERE  dbid = DB_ID('<SpectrumDB>') AND spid > 50
GROUP BY loginame, nt_domain, nt_username, hostname, program_name;


-- Q9. Plan cache: query text that touches the tables (no user info;
--     only what's still cached, so monthly jobs are usually missing)
SELECT TOP 500 DB_NAME(st.dbid) AS db, qs.execution_count, qs.last_execution_time,
       LEFT(st.text, 4000) AS query_text
FROM   sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE  EXISTS (SELECT 1 FROM #spectrum_tables t WHERE st.text LIKE '%' + t.table_name + '%')
ORDER BY qs.last_execution_time DESC;


/* =====================================================================
   Q10. WHO READS WHAT, GOING FORWARD - server-side SQL Trace
   CHANGE TICKET REQUIRED. Running before Nov 30, through Dec 31,
   until cutover.

   SQL Server Audit is Enterprise-only on 2008, so a server-side trace
   is the method on Standard edition. Server-side (sp_trace_*), not the
   Profiler GUI. Captures login, Windows user, host, application,
   database and statement text for RPC:Completed and SQL:BatchCompleted.

   Two traces, because a trace can't OR filters across columns:
     ctx: statements run with Spectrum as the current database
     xdb: statements from other databases that name <SpectrumDB>
          (three-part names, linked-server calls)

   Server-side traces stop when the service restarts. Step 10.1 is a
   proc with timestamped file names; step 10.2 runs it at every SQL
   Agent start, so a patch reboot doesn't leave a gap.
   ===================================================================== */

-- 10.1 Proc that starts both traces (no-op if they're already running)
/*
USE [<UtilDB>];
GO
CREATE PROCEDURE dbo.usp_start_spectrum_traces
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM sys.traces WHERE path LIKE N'%Spectrum[_]ctx[_]%') RETURN;

    DECLARE @t1 int, @t2 int, @rc int, @on bit, @maxsize bigint, @dbid int,
            @stamp nvarchar(20), @f1 nvarchar(245), @f2 nvarchar(245), @c int;
    SET @on = 1;
    SET @maxsize = 256;                 -- MB per file; rolls over
    SET @dbid = DB_ID('<SpectrumDB>');
    SET @stamp = REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(16), GETDATE(), 120), '-', ''), ':', ''), ' ', '_');
    SET @f1 = N'<TracePath>\Spectrum_ctx_' + @stamp;   -- no .trc; SQL adds it
    SET @f2 = N'<TracePath>\Spectrum_xdb_' + @stamp;

    EXEC @rc = sp_trace_create @t1 OUTPUT, 2, @f1, @maxsize, NULL, 40;
    IF @rc <> 0 BEGIN RAISERROR('ctx trace create failed: %d', 16, 1, @rc); RETURN; END
    EXEC @rc = sp_trace_create @t2 OUTPUT, 2, @f2, @maxsize, NULL, 20;
    IF @rc <> 0 BEGIN RAISERROR('xdb trace create failed: %d', 16, 1, @rc); RETURN; END

    -- columns: 1 TextData, 3 DatabaseID, 6 NTUserName, 7 NTDomainName, 8 HostName,
    --          10 ApplicationName, 11 LoginName, 14 StartTime, 35 DatabaseName
    -- events:  10 RPC:Completed, 12 SQL:BatchCompleted
    DECLARE @cols TABLE (c int);
    INSERT INTO @cols VALUES (1), (3), (6), (7), (8), (10), (11), (14), (35);
    DECLARE col_cur CURSOR LOCAL FAST_FORWARD FOR SELECT c FROM @cols;
    OPEN col_cur;
    FETCH NEXT FROM col_cur INTO @c;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_trace_setevent @t1, 10, @c, @on;  EXEC sp_trace_setevent @t1, 12, @c, @on;
        EXEC sp_trace_setevent @t2, 10, @c, @on;  EXEC sp_trace_setevent @t2, 12, @c, @on;
        FETCH NEXT FROM col_cur INTO @c;
    END
    CLOSE col_cur; DEALLOCATE col_cur;

    EXEC sp_trace_setfilter @t1, 3, 0, 0, @dbid;                 -- DatabaseID = Spectrum
    EXEC sp_trace_setfilter @t2, 1, 0, 6, N'%<SpectrumDB>%';     -- TextData LIKE
    EXEC sp_trace_setfilter @t2, 3, 0, 1, @dbid;                 -- and DatabaseID <> Spectrum

    EXEC sp_trace_setstatus @t1, 1;
    EXEC sp_trace_setstatus @t2, 1;
END
GO
EXEC dbo.usp_start_spectrum_traces;     -- start now
SELECT id, path, max_size, max_files, start_time FROM sys.traces;   -- confirm both are listed
*/

-- 10.2 SQL Agent job "Spectrum trace - start"
--      Step: EXEC [<UtilDB>].dbo.usp_start_spectrum_traces;
--      Schedule type: "Start automatically when SQL Server Agent starts"
--      (SQL Agent must be set to start automatically with the service)

-- 10.3 Check disk after the first day. Size = files in <TracePath>.
--      If it's growing fast, raise @maxsize/filecount or move the path;
--      don't drop the xdb trace, it's the one that catches the unknowns.

-- 10.4 Weekly summary: load every trace file set (including sets from
--      before a restart), then summarise identity x table.
/*
USE [<UtilDB>];
IF OBJECT_ID('dbo.spectrum_trace_load') IS NOT NULL DROP TABLE dbo.spectrum_trace_load;
CREATE TABLE dbo.spectrum_trace_load (
    trace_set nvarchar(260), LoginName nvarchar(256), NTDomainName nvarchar(256),
    NTUserName nvarchar(256), HostName nvarchar(256), ApplicationName nvarchar(256),
    DatabaseName nvarchar(256), StartTime datetime, txt nvarchar(max));

DECLARE @files TABLE (subdirectory nvarchar(260), depth int, isfile bit);
INSERT INTO @files EXEC master.sys.xp_dirtree N'<TracePath>', 1, 1;

DECLARE @f nvarchar(260), @p nvarchar(260);
DECLARE f_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT subdirectory FROM @files
    WHERE  isfile = 1
      AND  subdirectory LIKE N'Spectrum[_]___[_]________[_]____.trc';   -- first file of each set only
OPEN f_cur;
FETCH NEXT FROM f_cur INTO @f;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @p = N'<TracePath>\' + @f;
    INSERT INTO dbo.spectrum_trace_load
    SELECT @f, LoginName, NTDomainName, NTUserName, HostName, ApplicationName,
           DatabaseName, StartTime, CAST(TextData AS nvarchar(max))
    FROM   fn_trace_gettable(@p, DEFAULT);                -- DEFAULT reads the rollover files too
    FETCH NEXT FROM f_cur INTO @f;
END
CLOSE f_cur; DEALLOCATE f_cur;

-- re-create #spectrum_tables (Q0), then:
SELECT l.LoginName, l.NTDomainName + '\' + l.NTUserName AS windows_user,
       l.HostName, l.ApplicationName, l.DatabaseName AS context_db, s.table_name,
       COUNT(*) AS statements, MIN(l.StartTime) AS first_seen, MAX(l.StartTime) AS last_seen
FROM   dbo.spectrum_trace_load l
JOIN   #spectrum_tables s ON l.txt LIKE '%' + s.table_name + '%'
GROUP BY l.LoginName, l.NTDomainName + '\' + l.NTUserName, l.HostName,
         l.ApplicationName, l.DatabaseName, s.table_name
ORDER BY statements DESC;
-- Rows from the ION load and the Data Platform pull are expected; they
-- are known consumers. Everything else is what we're looking for.
-- Statements calling stored procedures show the proc name, not the
-- tables: match those against Q4.
*/

-- 10.5 Stop at cutover (ids from sys.traces):
--      EXEC sp_trace_setstatus <id>, 0;  EXEC sp_trace_setstatus <id>, 2;
--      and disable the 10.2 Agent job.


/* FALLBACK if the trace is refused: connection sampler
   Agent job every 5 minutes. Shows who connects and from where, not
   which tables. Misses connections shorter than the interval.

CREATE TABLE dbo.spectrum_session_log (
    sampled_at   datetime, loginame nvarchar(128), nt_domain nvarchar(128),
    nt_username  nvarchar(128), hostname nvarchar(128), program_name nvarchar(128),
    last_batch   datetime);        -- create in <UtilDB>

INSERT INTO dbo.spectrum_session_log
SELECT GETDATE(), loginame, nt_domain, nt_username, hostname, program_name, last_batch
FROM   sys.sysprocesses
WHERE  dbid = DB_ID('<SpectrumDB>') AND spid > 50;
*/


/* Q11. Other instances
   On every other SQL Server instance, list linked servers that point at
   the Spectrum host, and run Q4 there:
   SELECT name, data_source, provider FROM sys.servers WHERE is_linked = 1;
*/
