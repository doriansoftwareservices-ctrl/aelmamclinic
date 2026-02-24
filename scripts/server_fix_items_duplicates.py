#!/usr/bin/env python3
import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def http_json(url, payload, admin_secret):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("x-hasura-admin-secret", admin_secret)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body)
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8")
        except Exception:
            body = "<no response body>"
        raise RuntimeError(f"HTTP {e.code} for {url}: {body}") from e


def run_sql(sql, hasura_base, admin_secret, read_only=False):
    payload = {
        "type": "run_sql",
        "args": {"source": "default", "read_only": read_only, "sql": sql},
    }
    try:
        return http_json(hasura_base + "/v2/query", payload, admin_secret)
    except RuntimeError as e:
        raise RuntimeError(f"{e}\nSQL:\n{sql}") from e


def guess_hasura_base():
    if os.getenv("HASURA_URL"):
        return os.getenv("HASURA_URL").rstrip("/")
    if os.getenv("NHOST_SUBDOMAIN") and os.getenv("NHOST_REGION"):
        sub = os.getenv("NHOST_SUBDOMAIN")
        reg = os.getenv("NHOST_REGION")
        return f"https://{sub}.hasura.{reg}.nhost.run"
    cfg_path = os.path.join(os.getcwd(), "config.json")
    if os.path.exists(cfg_path):
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        graphql = cfg.get("graphql", "")
        if graphql.endswith("/v1/graphql"):
            return graphql[: -len("/v1/graphql")]
    return ""


def fetch_table_columns(hasura_base, admin_secret):
    sql = """
      SELECT table_name, column_name
        FROM information_schema.columns
       WHERE table_schema='public'
    ORDER BY table_name, ordinal_position
    """
    res = run_sql(sql, hasura_base, admin_secret, read_only=True)
    rows = res.get("result", [])[1:]
    cols = {}
    for table_name, column_name in rows:
        cols.setdefault(table_name, []).append(column_name)
    return cols


def fetch_attname_map(hasura_base, admin_secret):
    sql = """
      SELECT c.relname as table_name, a.attnum, a.attname
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
       WHERE c.relnamespace = 'public'::regnamespace
         AND a.attnum > 0
         AND NOT a.attisdropped
    ORDER BY c.relname, a.attnum
    """
    res = run_sql(sql, hasura_base, admin_secret, read_only=True)
    rows = res.get("result", [])[1:]
    out = {}
    for table_name, attnum, attname in rows:
        out.setdefault(table_name, {})[int(attnum)] = attname
    return out


def parse_pg_array(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(x) for x in value]
    if isinstance(value, str):
        s = value.strip()
        if s.startswith("{") and s.endswith("}"):
            s = s[1:-1]
        if not s:
            return []
        return [x for x in s.split(",") if x]
    return [str(value)]


def fetch_item_fk_children(hasura_base, admin_secret, att_map):
    sql = """
      SELECT conname,
             conrelid::regclass::text as child_table,
             confrelid::regclass::text as parent_table,
             conkey,
             confkey
        FROM pg_constraint
       WHERE contype='f'
         AND connamespace = 'public'::regnamespace
         AND confrelid = 'public.items'::regclass
    ORDER BY conname
    """
    res = run_sql(sql, hasura_base, admin_secret, read_only=True)
    rows = res.get("result", [])[1:]
    out = []
    for conname, child_table, parent_table, conkey, confkey in rows:
        conkey_list = parse_pg_array(conkey)
        confkey_list = parse_pg_array(confkey)
        if len(conkey_list) != 1 or len(confkey_list) != 1:
            continue
        child_col = att_map.get(child_table, {}).get(int(conkey_list[0]))
        parent_col = att_map.get(parent_table, {}).get(int(confkey_list[0]))
        if not child_col or not parent_col:
            continue
        out.append((conname, child_table, child_col))
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Fix duplicate items on server by merging to a single canonical row."
    )
    ap.add_argument("--apply", action="store_true", help="Apply changes.")
    ap.add_argument(
        "--out",
        default="server_fix_items_duplicates_report.txt",
        help="Output report path.",
    )
    args = ap.parse_args()

    admin_secret = os.getenv("HASURA_ADMIN_SECRET")
    if not admin_secret:
        die("Missing HASURA_ADMIN_SECRET in environment.")

    hasura_base = guess_hasura_base()
    if not hasura_base:
        die(
            "Cannot determine Hasura base URL. Set HASURA_URL or NHOST_SUBDOMAIN/NHOST_REGION."
        )

    cols = fetch_table_columns(hasura_base, admin_secret)
    att_map = fetch_attname_map(hasura_base, admin_secret)
    fk_children = fetch_item_fk_children(hasura_base, admin_secret, att_map)

    report = []
    report.append("Server Fix Items Duplicates Report")
    report.append(f"Generated: {datetime.now().isoformat(timespec='seconds')}")
    report.append(f"Hasura: {hasura_base}")
    report.append(f"Apply: {args.apply}")
    report.append("")

    dup_sql = """
      SELECT account_id, type_id, lower("name") as name_key,
             array_agg(id ORDER BY id) as ids,
             array_agg(stock ORDER BY id) as stocks
        FROM items
       WHERE COALESCE(is_deleted,false)=false
    GROUP BY account_id, type_id, lower("name")
      HAVING COUNT(*) > 1
    ORDER BY account_id, type_id, name_key
    """
    dup_res = run_sql(dup_sql, hasura_base, admin_secret, read_only=True)
    dup_rows = dup_res.get("result", [])[1:]
    report.append(f"Duplicate groups: {len(dup_rows)}")

    if not dup_rows:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write("\n".join(report))
        print(f"Wrote report to {args.out}")
        return

    # Apply fixes per group
    for row in dup_rows:
        account_id, type_id, name_key, ids, stocks = row
        if isinstance(ids, str) or isinstance(ids, list):
            ids = parse_pg_array(ids)
        if isinstance(stocks, str):
            stocks = [float(x) for x in parse_pg_array(stocks)]
        ids = [str(x) for x in ids]
        keep_id = ids[0]
        drop_ids = ids[1:]
        max_stock = max([float(s) for s in stocks]) if stocks else None

        report.append(
            f"- account_id={account_id} type_id={type_id} name_key={name_key} keep={keep_id} drop={drop_ids}"
        )

        if not args.apply:
            continue

        sqls = []
        sqls.append("BEGIN;")

        # Repoint child tables
        for conname, child_table, child_col in fk_children:
            child_cols = set(cols.get(child_table, []))
            drop_list = ",".join(f"'{x}'" for x in drop_ids)
            where = [f'"{child_col}" IN ({drop_list})']
            if "account_id" in child_cols:
                where.append(f"account_id = '{account_id}'")
            where_sql = " AND ".join(where)
            sqls.append(
                f'UPDATE {child_table} SET "{child_col}" = \'{keep_id}\' WHERE {where_sql};'
            )

        # Update keep stock to max to avoid losing higher value
        if max_stock is not None:
            sqls.append(
                f"UPDATE items SET stock = {max_stock} WHERE id = '{keep_id}';"
            )

        # Delete duplicates
        drop_list = ",".join(f"'{x}'" for x in drop_ids)
        sqls.append(f"DELETE FROM items WHERE id IN ({drop_list});")
        sqls.append("COMMIT;")

        for sql in sqls:
            run_sql(sql, hasura_base, admin_secret, read_only=False)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(report))

    print(f"Wrote report to {args.out}")


if __name__ == "__main__":
    main()
