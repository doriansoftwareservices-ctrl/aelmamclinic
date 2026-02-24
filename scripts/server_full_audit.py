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


def run_sql(sql, hasura_base, admin_secret, read_only=True):
    payload = {
        "type": "run_sql",
        "args": {"source": "default", "read_only": read_only, "sql": sql},
    }
    try:
        return http_json(hasura_base + "/v2/query", payload, admin_secret)
    except RuntimeError as e:
        raise RuntimeError(f"{e}\nSQL:\n{sql}") from e


def meta_call(call_type, args, hasura_base, admin_secret):
    payload = {"type": call_type, "args": args or {}}
    return http_json(hasura_base + "/v1/metadata", payload, admin_secret)


def guess_hasura_base():
    if os.getenv("HASURA_URL"):
        return os.getenv("HASURA_URL").rstrip("/")
    if os.getenv("NHOST_SUBDOMAIN") and os.getenv("NHOST_REGION"):
        sub = os.getenv("NHOST_SUBDOMAIN")
        reg = os.getenv("NHOST_REGION")
        return f"https://{sub}.hasura.{reg}.nhost.run"
    # try config.json
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
    res = run_sql(sql, hasura_base, admin_secret)
    rows = res.get("result", [])[1:]
    cols = {}
    for table_name, column_name in rows:
        cols.setdefault(table_name, []).append(column_name)
    return cols


def fetch_table_column_types(hasura_base, admin_secret):
    sql = """
      SELECT table_name, column_name, data_type
        FROM information_schema.columns
       WHERE table_schema='public'
    ORDER BY table_name, ordinal_position
    """
    res = run_sql(sql, hasura_base, admin_secret)
    rows = res.get("result", [])[1:]
    out = {}
    for table_name, column_name, data_type in rows:
        out.setdefault(table_name, {})[column_name] = data_type
    return out


def fetch_tables(hasura_base, admin_secret):
    sql = """
      SELECT table_name
        FROM information_schema.tables
       WHERE table_schema='public' AND table_type='BASE TABLE'
    ORDER BY table_name
    """
    res = run_sql(sql, hasura_base, admin_secret)
    rows = res.get("result", [])[1:]
    return [r[0] for r in rows]


def fetch_fk_constraints(hasura_base, admin_secret):
    sql = """
      SELECT conname,
             conrelid::regclass::text as child_table,
             confrelid::regclass::text as parent_table,
             conkey,
             confkey
        FROM pg_constraint
       WHERE contype='f'
         AND connamespace = 'public'::regnamespace
    ORDER BY conname
    """
    res = run_sql(sql, hasura_base, admin_secret)
    rows = res.get("result", [])[1:]
    return rows


def parse_pg_int_array(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [int(x) for x in value]
    if isinstance(value, str):
        s = value.strip()
        if s.startswith("{") and s.endswith("}"):
            s = s[1:-1]
        if not s:
            return []
        return [int(x) for x in s.split(",") if x]
    return [int(value)]


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
    res = run_sql(sql, hasura_base, admin_secret)
    rows = res.get("result", [])[1:]
    out = {}
    for table_name, attnum, attname in rows:
        out.setdefault(table_name, {})[int(attnum)] = attname
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Full server audit for Hasura/Nhost (metadata + data checks)."
    )
    ap.add_argument(
        "--out",
        default="server_full_audit_report.txt",
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

    lines = []
    lines.append("Server Full Audit Report")
    lines.append(f"Generated: {datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"Hasura: {hasura_base}")
    lines.append("")

    # Metadata inconsistencies
    try:
        inconsistent = meta_call("get_inconsistent_metadata", {}, hasura_base, admin_secret)
        inc_list = inconsistent.get("is_consistent")
        lines.append("Metadata consistency:")
        if inc_list is True:
            lines.append("- is_consistent: true")
        else:
            lines.append("- is_consistent: false")
            details = inconsistent.get("inconsistent_objects", [])
            lines.append(f"- inconsistent_objects: {len(details)}")
            for obj in details[:50]:
                lines.append(f"  - {obj.get('type')}: {obj.get('name')}")
        lines.append("")
    except Exception as e:
        lines.append(f"Metadata consistency check failed: {e}")
        lines.append("")

    # Export metadata snapshot
    try:
        md = meta_call("export_metadata", {}, hasura_base, admin_secret)
        md_path = "server_full_audit_metadata.json"
        with open(md_path, "w", encoding="utf-8") as f:
            json.dump(md, f, ensure_ascii=False, indent=2)
        lines.append(f"Metadata snapshot saved: {md_path}")
        lines.append("")
    except Exception as e:
        lines.append(f"Metadata export failed: {e}")
        lines.append("")

    # Tables and columns
    tables = fetch_tables(hasura_base, admin_secret)
    cols = fetch_table_columns(hasura_base, admin_secret)
    col_types = fetch_table_column_types(hasura_base, admin_secret)

    lines.append("Table row counts and null checks:")
    for t in tables:
        count_all = run_sql(f"SELECT COUNT(*) FROM {t}", hasura_base, admin_secret)["result"][1][0]
        line = f"- {t}: {count_all}"
        tcols = set(cols.get(t, []))
        if "account_id" in tcols:
            nulls = run_sql(
                f"SELECT COUNT(*) FROM {t} WHERE account_id IS NULL",
                hasura_base,
                admin_secret,
            )["result"][1][0]
            line += f" | account_id NULL: {nulls}"
        if "device_id" in tcols:
            nulls = run_sql(
                f"SELECT COUNT(*) FROM {t} WHERE device_id IS NULL",
                hasura_base,
                admin_secret,
            )["result"][1][0]
            line += f" | device_id NULL: {nulls}"
        if "isDeleted" in tcols:
            if col_types.get(t, {}).get("isDeleted") == "boolean":
                deleted_sql = f"SELECT COUNT(*) FROM {t} WHERE COALESCE(isDeleted,false)=true"
            else:
                deleted_sql = f"SELECT COUNT(*) FROM {t} WHERE COALESCE(isDeleted,0)=1"
            deleted = run_sql(
                deleted_sql,
                hasura_base,
                admin_secret,
            )["result"][1][0]
            nulld = run_sql(
                f"SELECT COUNT(*) FROM {t} WHERE isDeleted IS NULL",
                hasura_base,
                admin_secret,
            )["result"][1][0]
            line += f" | deleted: {deleted} | isDeleted NULL: {nulld}"
        if "is_deleted" in tcols:
            deleted = run_sql(
                f"SELECT COUNT(*) FROM {t} WHERE COALESCE(is_deleted,false)=true",
                hasura_base,
                admin_secret,
            )["result"][1][0]
            nulld = run_sql(
                f"SELECT COUNT(*) FROM {t} WHERE is_deleted IS NULL",
                hasura_base,
                admin_secret,
            )["result"][1][0]
            line += f" | deleted: {deleted} | is_deleted NULL: {nulld}"
        lines.append(line)
    lines.append("")

    # Duplicate checks
    lines.append("Duplicate checks:")
    def check_dupes(table, cols_list, where=""):
        cols_sql = ", ".join(cols_list)
        sql = f"""
          SELECT {cols_sql}, COUNT(*)
            FROM {table}
           WHERE 1=1
             {where}
        GROUP BY {cols_sql}
          HAVING COUNT(*) > 1
        """
        res = run_sql(sql, hasura_base, admin_secret)
        rows = res.get("result", [])
        return max(0, len(rows) - 1)

    def soft_delete_clause(tcols, alias=None, col_types=None):
        prefix = f"{alias}." if alias else ""
        if "isDeleted" in tcols:
            if col_types and col_types.get("isDeleted") == "boolean":
                return f"AND COALESCE({prefix}isDeleted,false)=false"
            return f"AND COALESCE({prefix}isDeleted,0)=0"
        if "is_deleted" in tcols:
            if col_types and col_types.get("is_deleted") == "boolean":
                return f"AND COALESCE({prefix}is_deleted,false)=false"
            return f"AND COALESCE({prefix}is_deleted,0)=0"
        return ""

    tcols = cols.get("item_types", [])
    if "account_id" in tcols and "name" in tcols:
        soft = soft_delete_clause(tcols, col_types=col_types.get("item_types"))
        n = check_dupes(
            "item_types",
            ['account_id', 'lower("name")'],
            soft,
        )
        lines.append(f"- item_types duplicates: {n}")
    tcols = cols.get("items", [])
    if "account_id" in tcols and "type_id" in tcols and "name" in tcols:
        soft = soft_delete_clause(tcols, col_types=col_types.get("items"))
        n = check_dupes(
            "items",
            ['account_id', 'type_id', 'lower("name")'],
            soft,
        )
        lines.append(f"- items duplicates: {n}")
    tcols = cols.get("consumption_types", [])
    if "account_id" in tcols and "name" in tcols:
        soft = soft_delete_clause(
            tcols, col_types=col_types.get("consumption_types")
        )
        n = check_dupes(
            "consumption_types",
            ['account_id', 'lower("name")'],
            soft,
        )
        lines.append(f"- consumption_types duplicates: {n}")
    lines.append("")

    # FK integrity
    lines.append("Foreign key integrity (orphan counts):")
    fk_rows = fetch_fk_constraints(hasura_base, admin_secret)
    att_map = fetch_attname_map(hasura_base, admin_secret)
    for conname, child_table, parent_table, conkey, confkey in fk_rows:
        conkey_list = parse_pg_int_array(conkey)
        confkey_list = parse_pg_int_array(confkey)
        child_cols = [
            att_map.get(child_table, {}).get(int(x)) for x in conkey_list
        ]
        parent_cols = [
            att_map.get(parent_table, {}).get(int(x)) for x in confkey_list
        ]
        if None in child_cols or None in parent_cols:
            continue
        join_parts = []
        notnull_parts = []
        for ccol, pcol in zip(child_cols, parent_cols):
            join_parts.append(f'c."{ccol}" = p."{pcol}"')
            notnull_parts.append(f'c."{ccol}" IS NOT NULL')
        join_on = " AND ".join(join_parts)
        notnull_on = " AND ".join(notnull_parts)
        soft = soft_delete_clause(
            cols.get(child_table, []),
            alias="c",
            col_types=col_types.get(child_table),
        )
        sql = f"""
          SELECT COUNT(*)
            FROM {child_table} c
       LEFT JOIN {parent_table} p
              ON {join_on}
           WHERE {notnull_on}
             {soft}
             AND p.{parent_cols[0]} IS NULL
        """
        count = run_sql(sql, hasura_base, admin_secret)["result"][1][0]
        if int(count) > 0:
            lines.append(
                f"- {child_table}->{parent_table} ({conname}): {count} orphans"
            )
    lines.append("")

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"Wrote report to {args.out}")


if __name__ == "__main__":
    main()
