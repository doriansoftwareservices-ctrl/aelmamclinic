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


def main():
    ap = argparse.ArgumentParser(
        description="Fix account_id NULLs where safe (chat tables)."
    )
    ap.add_argument("--apply", action="store_true", help="Apply changes.")
    ap.add_argument(
        "--out",
        default="server_fix_account_nulls_report.txt",
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

    report = []
    report.append("Server Fix account_id NULLs Report")
    report.append(f"Generated: {datetime.now().isoformat(timespec='seconds')}")
    report.append(f"Hasura: {hasura_base}")
    report.append(f"Apply: {args.apply}")
    report.append("")

    # Fix chat_participants.account_id from chat_conversations.account_id
    count_sql = """
      SELECT COUNT(*)
        FROM chat_participants cp
        JOIN chat_conversations cc ON cc.id = cp.conversation_id
       WHERE cp.account_id IS NULL
         AND cc.account_id IS NOT NULL
    """
    fix_count = run_sql(count_sql, hasura_base, admin_secret, read_only=True)["result"][1][0]
    report.append(f"chat_participants: can fix {fix_count} rows via conversation_id")

    if args.apply and int(fix_count) > 0:
        run_sql(
            """
            UPDATE chat_participants cp
               SET account_id = cc.account_id
              FROM chat_conversations cc
             WHERE cp.conversation_id = cc.id
               AND cp.account_id IS NULL
               AND cc.account_id IS NOT NULL
            """,
            hasura_base,
            admin_secret,
            read_only=False,
        )

    # Fix chat_reads.account_id from chat_messages -> chat_conversations
    chat_reads_cols = set(cols.get("chat_reads", []))
    join_col = None
    for candidate in ["message_id", "chat_message_id", "message_uuid", "messageId"]:
        if candidate in chat_reads_cols:
            join_col = candidate
            break
    if join_col:
        count_sql = f"""
          SELECT COUNT(*)
            FROM chat_reads cr
            JOIN chat_messages cm ON cm.id = cr.{join_col}
            JOIN chat_conversations cc ON cc.id = cm.conversation_id
           WHERE cr.account_id IS NULL
             AND cc.account_id IS NOT NULL
        """
        fix_count = run_sql(count_sql, hasura_base, admin_secret, read_only=True)["result"][1][0]
        report.append(f"chat_reads: can fix {fix_count} rows via {join_col}")

        if args.apply and int(fix_count) > 0:
            run_sql(
                f"""
                UPDATE chat_reads cr
                   SET account_id = cc.account_id
                  FROM chat_messages cm
                  JOIN chat_conversations cc ON cc.id = cm.conversation_id
                 WHERE cr.{join_col} = cm.id
                   AND cr.account_id IS NULL
                   AND cc.account_id IS NOT NULL
                """,
                hasura_base,
                admin_secret,
                read_only=False,
            )
    else:
        report.append("chat_reads: skip (no message id column found)")

    # Report-only tables
    for table in ["profiles", "super_admins"]:
        cnt = run_sql(
            f"SELECT COUNT(*) FROM {table} WHERE account_id IS NULL",
            hasura_base,
            admin_secret,
            read_only=True,
        )["result"][1][0]
        report.append(f"{table}: account_id NULL = {cnt} (no auto-fix)")

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(report))

    print(f"Wrote report to {args.out}")


if __name__ == "__main__":
    main()
