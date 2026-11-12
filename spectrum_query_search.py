"""
Search Databricks SQL query history, saved queries and dashboards for
Spectrum table references. Works with hive_metastore tables (no Unity
Catalog or system tables needed).

Coverage: SQL warehouses (and serverless, where used). Classic-cluster
notebooks and jobs do not appear here; use the code search for those.

Run as a WORKSPACE ADMIN (or with CAN MANAGE on every warehouse).
A normal user only sees their own query history and the saved queries
shared with them.

Usage:
  export DATABRICKS_HOST=https://adb-<id>.azuredatabricks.net
  export DATABRICKS_TOKEN=<token>
  pip install requests
  python spectrum_query_search.py ./query_search_out [days_back]

Output:
  query_history_hits.csv   who ran what, on which warehouse, when
  saved_query_hits.csv     saved queries that reference Spectrum, with owner
  dashboard_hits.csv       dashboards whose datasets reference Spectrum
"""
import csv
import json
import os
import re
import sys
import time

import requests

HOST = os.environ["DATABRICKS_HOST"].rstrip("/")
HDRS = {"Authorization": f"Bearer {os.environ['DATABRICKS_TOKEN']}"}

# Extend with the remaining Spectrum table names
TERMS = ["fx_spectrum", "account_entry", "account_entry_detail", "cash_flow"]
PATTERN = re.compile("|".join(re.escape(t) for t in TERMS), re.IGNORECASE)


def get(path, body=None, params=None):
    for attempt in range(5):
        r = requests.get(f"{HOST}{path}", headers=HDRS, json=body, params=params, timeout=120)
        if r.status_code == 429:
            time.sleep(2 ** attempt)
            continue
        r.raise_for_status()
        return r.json()
    r.raise_for_status()


def matched_terms(text):
    return ",".join(sorted({m.group(0).lower() for m in PATTERN.finditer(text or "")}))


def query_history(days_back):
    end_ms = int(time.time() * 1000)
    start_ms = end_ms - days_back * 86400 * 1000
    body = {"max_results": 1000,
            "filter_by": {"query_start_time_range": {"start_time_ms": start_ms, "end_time_ms": end_ms}}}
    rows, token = [], None
    while True:
        b = {"max_results": 1000, "page_token": token} if token else body
        data = get("/api/2.0/sql/history/queries", body=b)
        for q in data.get("res", []):
            text = q.get("query_text", "")
            if PATTERN.search(text):
                rows.append({
                    "user": q.get("user_name", ""),
                    "executed_as": q.get("executed_as_user_name", ""),
                    "warehouse_id": q.get("warehouse_id") or q.get("endpoint_id", ""),
                    "start_time_ms": q.get("query_start_time_ms", ""),
                    "status": q.get("status", ""),
                    "statement_type": q.get("statement_type", ""),
                    "terms": matched_terms(text),
                    "query_text": text[:2000],
                })
        token = data.get("next_page_token")
        if not token or not data.get("has_next_page", True):
            return rows


def saved_queries():
    rows, token = [], None
    while True:
        params = {"page_size": 100}
        if token:
            params["page_token"] = token
        data = get("/api/2.0/sql/queries", params=params)
        for q in data.get("results", []):
            text = q.get("query_text") or q.get("query", "")
            if PATTERN.search(text):
                rows.append({
                    "query_id": q.get("id", ""),
                    "name": q.get("display_name") or q.get("name", ""),
                    "owner": q.get("owner_user_name", ""),
                    "warehouse_id": q.get("warehouse_id", ""),
                    "last_modified": q.get("update_time", ""),
                    "terms": matched_terms(text),
                    "query_text": text[:2000],
                })
        token = data.get("next_page_token")
        if not token:
            return rows


def dashboards():
    rows, token = [], None
    while True:
        params = {"page_size": 100}
        if token:
            params["page_token"] = token
        data = get("/api/2.0/lakeview/dashboards", params=params)
        for d in data.get("dashboards", []):
            try:
                full = get(f"/api/2.0/lakeview/dashboards/{d['dashboard_id']}")
            except requests.HTTPError:
                continue
            content = full.get("serialized_dashboard", "")
            if PATTERN.search(content):
                rows.append({
                    "dashboard_id": d["dashboard_id"],
                    "name": d.get("display_name", ""),
                    "path": full.get("path", ""),
                    "warehouse_id": full.get("warehouse_id", ""),
                    "terms": matched_terms(content),
                })
        token = data.get("next_page_token")
        if not token:
            return rows


def write(out, name, rows):
    path = os.path.join(out, name)
    if not rows:
        print(f"{name}: no hits")
        return
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"{name}: {len(rows)} hits")


def main():
    out = sys.argv[1]
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    os.makedirs(out, exist_ok=True)
    for name, fn in (("query_history_hits.csv", lambda: query_history(days)),
                     ("saved_query_hits.csv", saved_queries),
                     ("dashboard_hits.csv", dashboards)):
        try:
            write(out, name, fn())
        except requests.HTTPError as e:
            print(f"{name}: failed ({e}). Check permissions or that the feature is in use.")


if __name__ == "__main__":
    main()
