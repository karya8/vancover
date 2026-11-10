"""
Unity Catalog lineage for the fx_spectrum tables, via the Data Lineage
REST API. Use when the system tables (system.access.*) are not enabled.
Same data as the Lineage tab in Catalog Explorer.

Needs: BROWSE or SELECT on the tables, and a token for the workspace.

Usage:
  export DATABRICKS_HOST=https://adb-<id>.azuredatabricks.net
  export DATABRICKS_TOKEN=<personal access token or Entra token>
  pip install requests
  python spectrum_lineage_api.py <catalog> fx_spectrum ./lineage_out [col1,col2,...]

The optional last argument limits column lineage to those columns
(e.g. entity_type,address). Without it, every column of every table is
checked, which is one API call per column.

Output in ./lineage_out:
  raw/                 raw JSON per table and per column
  table_lineage.csv    one row per downstream table/notebook/job/query/dashboard
  column_lineage.csv   one row per downstream column
"""
import csv
import json
import os
import sys
import time

import requests

HOST = os.environ["DATABRICKS_HOST"].rstrip("/")
HDRS = {"Authorization": f"Bearer {os.environ['DATABRICKS_TOKEN']}"}


def get(path, body=None, params=None):
    for attempt in range(5):
        r = requests.get(f"{HOST}{path}", headers=HDRS, json=body, params=params, timeout=60)
        if r.status_code == 429:
            time.sleep(2 ** attempt)
            continue
        r.raise_for_status()
        return r.json()
    r.raise_for_status()


def list_tables(catalog, schema):
    tables, token = [], None
    while True:
        params = {"catalog_name": catalog, "schema_name": schema}
        if token:
            params["page_token"] = token
        data = get("/api/2.1/unity-catalog/tables", params=params)
        tables.extend(data.get("tables", []))
        token = data.get("next_page_token")
        if not token:
            return tables


def flatten(table, direction, items):
    """Each lineage item holds keys like tableInfo, notebookInfos, jobInfos,
    queryInfos, dashboardInfos. Emit one row per entity, keeping the detail."""
    rows = []
    for item in items or []:
        for kind, val in item.items():
            for v in (val if isinstance(val, list) else [val]):
                rows.append({
                    "spectrum_table": table,
                    "direction": direction,
                    "kind": kind,
                    "name": v.get("name") or v.get("table_name") or "",
                    "catalog": v.get("catalog_name", ""),
                    "schema": v.get("schema_name", ""),
                    "job_id": v.get("job_id", ""),
                    "notebook_id": v.get("notebook_id", ""),
                    "workspace_id": v.get("workspace_id", ""),
                    "lineage_timestamp": v.get("lineage_timestamp", ""),
                    "detail": json.dumps(v),
                })
    return rows


def main():
    catalog, schema, out = sys.argv[1], sys.argv[2], sys.argv[3]
    only_cols = set(sys.argv[4].split(",")) if len(sys.argv) > 4 else None
    raw = os.path.join(out, "raw")
    os.makedirs(raw, exist_ok=True)

    t_rows, c_rows = [], []
    for t in list_tables(catalog, schema):
        full = f"{catalog}.{schema}.{t['name']}"
        tl = get("/api/2.0/lineage-tracking/table-lineage",
                 body={"table_name": full, "include_entity_lineage": True})
        json.dump(tl, open(os.path.join(raw, f"{t['name']}.json"), "w"), indent=2)
        t_rows += flatten(full, "downstream", tl.get("downstreams"))
        t_rows += flatten(full, "upstream", tl.get("upstreams"))

        for col in t.get("columns", []):
            if only_cols and col["name"] not in only_cols:
                continue
            cl = get("/api/2.0/lineage-tracking/column-lineage",
                     body={"table_name": full, "column_name": col["name"]})
            json.dump(cl, open(os.path.join(raw, f"{t['name']}__{col['name']}.json"), "w"), indent=2)
            for d in cl.get("downstream_cols", []) or []:
                c_rows.append({
                    "spectrum_table": full,
                    "spectrum_column": col["name"],
                    "downstream_table": ".".join(filter(None, [d.get("catalog_name"),
                                                               d.get("schema_name"),
                                                               d.get("table_name")])),
                    "downstream_column": d.get("name", ""),
                })
            time.sleep(0.1)
        print(f"done {full}")

    for name, rows in (("table_lineage.csv", t_rows), ("column_lineage.csv", c_rows)):
        if rows:
            with open(os.path.join(out, name), "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)
    print(f"{len(t_rows)} table-lineage rows, {len(c_rows)} column-lineage rows -> {out}")


if __name__ == "__main__":
    main()
