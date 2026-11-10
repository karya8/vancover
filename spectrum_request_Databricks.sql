/* =====================================================================
   REQUEST FOR: Databricks platform admin (metastore / workspace admin)
   From: Kapil, BSA, FX Spectrum migration

   Why: the 17 fx_spectrum tables change structure with the new ION
   model. We need every job, notebook, query, dashboard, user and
   downstream table that reads them, including which columns.

   What to run: a SQL warehouse attached to the PRODUCTION metastore.
   Everything reads metadata and logs only, no business data.

   What to send back: one CSV per query (D0.csv, D1.csv, ...), with headers.

   Placeholder: <uc_catalog>  (catalog that holds fx_spectrum)

   Step 0 decides the path:
     - system schemas enabled  -> run D1-D9
     - not enabled             -> run D1, D7, D8 (they don't need them),
                                  then the FALLBACK section at the end
   ===================================================================== */

-- D0. Are system schemas enabled, and how far back does history go?
SHOW SCHEMAS IN system;          -- look for access, query, lakeflow
SELECT 'table_lineage' AS src, MIN(event_date) AS earliest FROM system.access.table_lineage
UNION ALL SELECT 'audit',         MIN(event_date) FROM system.access.audit
UNION ALL SELECT 'query_history', CAST(MIN(start_time) AS DATE) FROM system.query.history;


-- D1. Grants (information_schema is available even without system schemas)
SELECT 'TABLE' AS level, grantee, table_schema, table_name, privilege_type, inherited_from
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
-- Also: export members of every group in this result (admin console / SCIM).


-- D2. Who reads the tables (table lineage, 12 months)
WITH jobs AS (
  SELECT workspace_id, job_id, name AS job_name, creator_id, run_as
  FROM   system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1
)
SELECT l.source_table_name, l.entity_type, l.entity_id,
       j.job_name, j.run_as, j.creator_id, l.created_by,
       l.target_table_full_name, l.workspace_id,
       MIN(l.event_date) AS first_seen, MAX(l.event_date) AS last_seen,
       COUNT(DISTINCT l.event_date) AS active_days
FROM   system.access.table_lineage l
LEFT JOIN jobs j ON l.entity_type = 'JOB' AND j.job_id = l.entity_id AND j.workspace_id = l.workspace_id
WHERE  l.source_table_catalog = '<uc_catalog>' AND l.source_table_schema = 'fx_spectrum'
  AND  l.event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL
ORDER BY l.source_table_name, last_seen DESC;


-- D3. Who reads every column (all columns, so unchanged ones prove "no impact")
SELECT source_table_name, source_column_name, target_table_full_name, target_column_name,
       entity_type, entity_id, created_by, MAX(event_date) AS last_seen
FROM   system.access.column_lineage
WHERE  source_table_catalog = '<uc_catalog>' AND source_table_schema = 'fx_spectrum'
  AND  event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL;


-- D4. Second hop: readers of tables built from fx_spectrum
WITH hop1 AS (
  SELECT DISTINCT target_table_full_name AS t
  FROM   system.access.table_lineage
  WHERE  source_table_catalog = '<uc_catalog>' AND source_table_schema = 'fx_spectrum'
    AND  target_table_full_name IS NOT NULL
    AND  event_date >= current_date() - INTERVAL 365 DAYS
)
SELECT l.source_table_full_name AS spectrum_derived_table, l.entity_type, l.entity_id,
       l.created_by, l.target_table_full_name, l.target_type, MAX(l.event_date) AS last_seen
FROM   system.access.table_lineage l
JOIN   hop1 h ON h.t = l.source_table_full_name
WHERE  l.event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL;


-- D5. BI tools, JDBC/ODBC, ad hoc SQL
SELECT executed_by, client_application, compute.warehouse_id,
       COUNT(*) AS queries, MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
FROM   system.query.history
WHERE  statement_text ILIKE '%fx_spectrum%'
  AND  start_time >= current_timestamp() - INTERVAL 180 DAYS
GROUP BY ALL ORDER BY queries DESC;


-- D6. Identities that opened the tables (audit)
SELECT user_identity.email AS identity, request_params.full_name_arg AS table_name,
       user_agent, source_ip_address, COUNT(*) AS events, MAX(event_date) AS last_seen
FROM   system.access.audit
WHERE  service_name = 'unityCatalog' AND action_name = 'getTable'
  AND  request_params.full_name_arg LIKE '<uc_catalog>.fx_spectrum.%'
  AND  event_date >= current_date() - INTERVAL 365 DAYS
GROUP BY ALL ORDER BY events DESC;


-- D7. Views over the tables (no system schemas needed)
SELECT table_catalog, table_schema, table_name
FROM   system.information_schema.views
WHERE  view_definition ILIKE '%fx_spectrum%';


-- D8. Delta Sharing (no system schemas needed)
-- SHOW SHARES;   then for each:  SHOW ALL IN SHARE <share_name>;


-- D9. Job inventory with owners (to name the team behind each job ID)
SELECT workspace_id, job_id, name, creator_id, run_as
FROM   system.lakeflow.jobs
QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1;


/* =====================================================================
   FALLBACK - system schemas NOT enabled

   F1. Ask the account admin to enable access, query and lakeflow now.
       It's a metastore-level setting, no cost to switch on.
       Re-run D0 afterwards: history may only start from the enable
       date, so the window effectively starts then.

   F2. Lineage without system tables. Unity Catalog records lineage
       whether or not the system tables are enabled. Two ways to read it:
       - Catalog Explorer > table > Lineage tab (manual, per table)
       - Data Lineage REST API, scripted for all 17 tables:
         run spectrum_lineage_api.py (sent with this file). Anyone with
         BROWSE or SELECT on the tables can run it; I can run it myself
         if I get that grant.

   F3. Audit logs may already go to Azure Log Analytics through the
       workspace's diagnostic settings (security teams often set this
       up). If so, KQL in that workspace:

       DatabricksUnityCatalog
       | where TimeGenerated > ago(365d)
       | where ActionName == "getTable"
       | where RequestParams has "fx_spectrum"
       | summarize events = count(), last_seen = max(TimeGenerated)
                 by Identity, tostring(RequestParams), UserAgent

   F4. Code search (finds jobs that exist even if they haven't run):
         databricks jobs list --output json > jobs.json
         databricks workspace export-dir / ./ws_export
         grep -rilE "fx_spectrum|account_entry|cash_flow" ./ws_export
       Plus the same grep across the ADO repos (notebooks, ADF JSON,
       Airflow DAGs).

   F5. SQL warehouse query history: SQL > Query History, filter on
       text "fx_spectrum", per warehouse. Shorter retention than the
       system table; export what's there.
   ===================================================================== */
