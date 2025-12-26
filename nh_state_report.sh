#!/usr/bin/env bash
set -euo pipefail

SUBDOMAIN="${1:-mergrgclboxflnucehgb}"
REGION="${REGION:-ap-southeast-1}"
TIMEOUT="${TIMEOUT:-30m}"
OUT="${OUT:-server_state_${SUBDOMAIN}_$(date +%Y%m%d_%H%M%S).md}"

# Load secrets if present (created by `nhost config pull`)
if [ -f ".secrets" ]; then
  set -a
  # shellcheck disable=SC1091
  source ./.secrets 2>/dev/null || true
  set +a
fi

HASURA_ADMIN_SECRET="${HASURA_ADMIN_SECRET:-${HASURA_GRAPHQL_ADMIN_SECRET:-}}"
HASURA_BASE="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run"
METADATA_URL="${HASURA_BASE}/v1/metadata"
GRAPHQL_URL="${HASURA_BASE}/v1/graphql"

# Helper: append section
sec() { printf "\n## %s\n\n" "$1" >> "$OUT"; }

# Start report
cat > "$OUT" <<EOF
# Server State Report (Nhost/Hasura)
- Subdomain: \`$SUBDOMAIN\`
- Region: \`$REGION\`
- Generated: \`$(date -Is)\`

> This report lists deployments, cloud config validation, secrets (names only), and (if admin secret is available) Hasura metadata + database schema + key GraphQL fields.
EOF

sec "Nhost CLI Version"
{
  echo '```'
  nhost sw version 2>/dev/null || nhost --version 2>/dev/null || echo "(could not detect CLI version)"
  echo '```'
} >> "$OUT"

sec "Cloud Config Validation"
{
  echo '```'
  nhost config validate --subdomain "$SUBDOMAIN" || true
  echo '```'
} >> "$OUT"

sec "Secrets (names only)"
{
  echo '```'
  nhost secrets list --subdomain "$SUBDOMAIN" || true
  echo '```'
} >> "$OUT"

sec "Deployments (list)"
DEPLOY_LIST="$(nhost deployments list --subdomain "$SUBDOMAIN" 2>&1 || true)"
{
  echo '```'
  echo "$DEPLOY_LIST"
  echo '```'
} >> "$OUT"

LATEST_ID="$(printf '%s\n' "$DEPLOY_LIST" | grep -Eo '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -n 1 || true)"

sec "Latest Deployment Logs"
{
  echo "**Latest ID:** \`$LATEST_ID\`"
  echo
  echo '```'
  if [ -n "${LATEST_ID:-}" ]; then
    nhost deployments logs "$LATEST_ID" --subdomain "$SUBDOMAIN" --timeout "$TIMEOUT" || true
  else
    echo "Could not detect latest deployment id."
  fi
  echo '```'
} >> "$OUT"

# Deep Hasura checks
sec "Hasura Deep Checks (Metadata + DB Schema)"
if [ -z "${HASURA_ADMIN_SECRET:-}" ]; then
  {
    echo "**SKIPPED** (HASURA_ADMIN_SECRET not found)."
    echo
    echo "To enable deep checks, set it then re-run:"
    echo '```'
    echo "export HASURA_ADMIN_SECRET='YOUR_ADMIN_SECRET'"
    echo "./nh_state_report.sh $SUBDOMAIN"
    echo '```'
  } >> "$OUT"
else
  {
    echo "- Hasura base: \`$HASURA_BASE\`"
    echo
    echo "### 1) Metadata Inconsistencies"
    echo '```'
    curl -sS "$METADATA_URL" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
      -d '{"type":"get_inconsistent_metadata","args":{}}' \
    | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
incs=d.get("inconsistent_objects",[])
print("inconsistent_objects_count =", len(incs))
if incs:
  for obj in incs[:10]:
    print("-", obj.get("type"), obj.get("reason"))
PY
    echo '```'

    echo
    echo "### 2) Export Metadata Summary (tracked tables/functions/actions)"
    echo '```'
    curl -sS "$METADATA_URL" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
      -d '{"type":"export_metadata","args":{}}' \
    | python3 - <<'PY'
import json,sys
m=json.load(sys.stdin)
sources=m.get("sources",[])
tables=0
functions=0
actions=0
events=0
crons=0
for s in sources:
  tables += len(s.get("tables",[]))
  functions += len(s.get("functions",[]))
actions = len(m.get("actions",{}).get("actions",[])) if isinstance(m.get("actions"),dict) else 0
events = len(m.get("event_triggers",[])) if isinstance(m.get("event_triggers"),list) else 0
crons = len(m.get("cron_triggers",[])) if isinstance(m.get("cron_triggers"),list) else 0
print("sources:", len(sources))
print("tracked_tables:", tables)
print("tracked_functions:", functions)
print("actions:", actions)
print("event_triggers:", events)
print("cron_triggers:", crons)
PY
    echo '```'

    echo
    echo "### 3) DB Schema (tables/views)"
    SQL_TABLES=$'select n.nspname as schema, c.relname as name, case c.relkind when \'r\' then \'table\' when \'v\' then \'view\' when \'m\' then \'mat_view\' else c.relkind::text end as kind\nfrom pg_class c join pg_namespace n on n.oid=c.relnamespace\nwhere n.nspname in (\'public\',\'auth\',\'storage\') and c.relkind in (\'r\',\'v\',\'m\')\norder by schema, kind, name;'
    echo '```'
    curl -sS "$METADATA_URL" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
      -d "$(python3 - <<PY
import json
print(json.dumps({"type":"run_sql","args":{"source":"default","sql":"""$SQL_TABLES"""}}))
PY
)" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
res=d.get("result")
if not res:
  print(d)
  raise SystemExit
hdr=res[0]; rows=res[1:]
print("\t".join(hdr))
for r in rows[:400]:
  print("\t".join(map(str,r)))
if len(rows)>400:
  print(f"... ({len(rows)-400} more rows)")
PY
    echo '```'

    echo
    echo "### 4) Key RPCs (existence + return types)"
    SQL_FUNCS=$"select n.nspname as schema, p.proname as name, pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result\nfrom pg_proc p join pg_namespace n on n.oid=p.pronamespace\nwhere n.nspname='public' and p.proname in (\n  'self_create_account','my_account_plan','my_feature_permissions',\n  'create_subscription_request','admin_approve_subscription_request','admin_reject_subscription_request',\n  'admin_set_account_plan','expire_account_subscriptions',\n  'admin_payment_stats','admin_payment_stats_by_plan','admin_payment_stats_by_day','admin_payment_stats_by_month'\n)\norder by p.proname, args;"
    echo '```'
    curl -sS "$METADATA_URL" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
      -d "$(python3 - <<PY
import json
print(json.dumps({"type":"run_sql","args":{"source":"default","sql":"""$SQL_FUNCS"""}}))
PY
)" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
res=d.get("result")
if not res:
  print(d); raise SystemExit
hdr=res[0]; rows=res[1:]
print("\t".join(hdr))
for r in rows:
  print("\t".join(map(str,r)))
PY
    echo '```'

    echo
    echo "### 5) GraphQL sanity (key mutations present?)"
    echo '```'
    curl -sS "$GRAPHQL_URL" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
      -d '{"query":"query { __schema { mutationType { fields { name } } } }"}' \
    | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
fields=[f["name"] for f in d["data"]["__schema"]["mutationType"]["fields"]]
need=["self_create_account","create_subscription_request","admin_approve_subscription_request","admin_reject_subscription_request"]
missing=[x for x in need if x not in fields]
print("mutations_total =", len(fields))
print("missing =", missing)
PY
    echo '```'
  } >> "$OUT"
fi

echo
echo "✅ Report saved to: $OUT"
