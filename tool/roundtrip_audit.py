#!/usr/bin/env python3
import argparse
import sqlite3
from datetime import datetime


def list_tables(conn):
    cur = conn.execute(
        """
        SELECT name
          FROM sqlite_master
         WHERE type='table'
           AND name NOT LIKE 'sqlite_%'
           AND name != 'android_metadata'
      ORDER BY name
        """
    )
    return [r[0] for r in cur.fetchall()]


def table_columns(conn, table):
    cur = conn.execute(f"PRAGMA table_info({table})")
    return [r[1] for r in cur.fetchall()]


def count_rows(conn, table, where=None):
    sql = f"SELECT COUNT(*) FROM {table}"
    if where:
        sql += f" WHERE {where}"
    cur = conn.execute(sql)
    return int(cur.fetchone()[0])


def fmt_count(value):
    return f"{value:,}"


def main():
    ap = argparse.ArgumentParser(
        description="Compare two SQLite databases for roundtrip sync auditing."
    )
    ap.add_argument("--before", required=True, help="Path to source DB (before).")
    ap.add_argument("--after", required=True, help="Path to synced DB (after).")
    ap.add_argument(
        "--out",
        default="roundtrip_audit_report.txt",
        help="Output report path.",
    )
    args = ap.parse_args()

    conn_before = sqlite3.connect(args.before)
    conn_after = sqlite3.connect(args.after)

    tables_before = set(list_tables(conn_before))
    tables_after = set(list_tables(conn_after))
    all_tables = sorted(tables_before | tables_after)

    lines = []
    lines.append("Roundtrip Audit Report")
    lines.append(f"Generated: {datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"Before: {args.before}")
    lines.append(f"After:  {args.after}")
    lines.append("")

    missing_before = sorted(tables_after - tables_before)
    missing_after = sorted(tables_before - tables_after)

    if missing_before:
        lines.append("Tables missing in BEFORE (exist only in AFTER):")
        for t in missing_before:
            lines.append(f"- {t}")
        lines.append("")

    if missing_after:
        lines.append("Tables missing in AFTER (exist only in BEFORE):")
        for t in missing_after:
            lines.append(f"- {t}")
        lines.append("")

    lines.append("Table row counts (all rows | live rows if isDeleted exists):")
    lines.append("")

    for t in all_tables:
        exists_before = t in tables_before
        exists_after = t in tables_after
        if not exists_before or not exists_after:
            continue

        cols_before = set(table_columns(conn_before, t))
        cols_after = set(table_columns(conn_after, t))
        has_is_deleted = "isDeleted" in cols_before and "isDeleted" in cols_after

        before_all = count_rows(conn_before, t)
        after_all = count_rows(conn_after, t)
        before_live = after_live = None
        if has_is_deleted:
            before_live = count_rows(conn_before, t, "ifnull(isDeleted,0)=0")
            after_live = count_rows(conn_after, t, "ifnull(isDeleted,0)=0")

        delta_all = after_all - before_all
        delta_live = None
        if before_live is not None and after_live is not None:
            delta_live = after_live - before_live

        line = f"- {t}: {fmt_count(before_all)} -> {fmt_count(after_all)} (delta {delta_all:+d})"
        if delta_live is not None:
            line += (
                f" | live {fmt_count(before_live)} -> {fmt_count(after_live)}"
                f" (delta {delta_live:+d})"
            )
        lines.append(line)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"Wrote report to {args.out}")


if __name__ == "__main__":
    main()
