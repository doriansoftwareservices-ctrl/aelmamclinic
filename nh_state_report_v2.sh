#!/usr/bin/env bash
set -euo pipefail

SUBDOMAIN="${1:-mergrgclboxflnucehgb}"
REGION="${REGION:-ap-southeast-1}"
TIMEOUT="${TIMEOUT:-30m}"
OUT="${OUT:-server_state_${SUBDOMAIN}_$(date +%Y%m%d_%H%M%S).md}"

# Load .secrets if present
if [ -f ".secrets" ]; then
  set -a
  # shellcheck disable=SC1091
  source ./.secrets 2>/dev/null || true
  set +a
fi

HASURA_ADMIN_SECRET="${HASURA_ADMIN_SECRET:-${HASURA_GRAPHQL_ADMIN_SECRET:-}}"
HASURA_BASE="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run"
META="${HASURA_BASE}/v1/metadata"
GQL="${HASURA_BASE}/v1/graphql"

sec(){ printf "\n## %s\n\n" "$1"; }

curl_json() {
  local url="$1"
  local payload="$2"
  local resp code body
  resp="$(curl -sS "$url" \
    -H "Content-Type: application/json" \
    ${HASURA_ADMIN_SECRET:+-H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET"} \
    -d "$payload" \
    -w "\n__HTTP__%{http_code}\n" || true)"

  code="$(printf '%s' "$resp" | tail -n 1 | sed 's/__HTTP__//; s/\r//g')"
  body="$(printf '%s' "$resp" | sed '$d')"

  printf '%s\n' "$body"
  printf '\n[http_status=%s]\n' "$code" 1>&2
  if [ "$code" != "200" ]; then
    printf '\n--- Non-200 response (first 400 chars) ---\n' 1>&2
    printf '%s' "$body" | head -c 400 1>&2 || true
    printf '\n----------------------------------------\n' 1>&2
    return 22
  fi
}

python_json_check() {
  python3 - <<'PY'
import sys, json
try:
  json.load(sys.stdin)
except Exception as e:
  print("JSON_PARSE_ERROR:", e)
  raise SystemExit(2)
PY
}

(
  echo "# Server State Report (Nhost/Hasura)"
  echo "- Subdomain: \`$SUBDOMAIN\`"
  echo "- Region: \`$REGION\`"
  echo "- Generated: \`$(date -Is)\`"
  echo

  sec "Nhost config validate"
  echo '```'
  nhost config validate --subdomain "$SUBDOMAIN" || true
  echo '```'
  echo

  sec "Cloud secrets (names only)"
  echo '```'
  nhost secrets list --subdomain "$SUBDOMAIN" || true
  echo '```'
  echo

  sec "Deployments list"
  DEP="$(nhost deployments list --subdomain "$SUBDOMAIN" 2>&1 || true)"
  echo '```'
  echo "$DEP"
  echo '```'
  echo

  ID="$(printf '%s\n' "$DEP" | grep -Eo '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -n 1 || true)"
  sec "Latest deployment logs"
  echo "**Latest ID:** \`${ID:-UNKNOWN}\`"
  echo
  echo '```'
  if [ -n "${ID:-}" ]; then
    nhost deployments logs "$ID" --subdomain "$SUBDOMAIN" --timeout "$TIMEOUT" || true
  else
    echo "Could not detect latest deployment id."
  fi
  echo '```'
  echo

  if [ -z "${HASURA_ADMIN_SECRET:-}" ]; then
    sec "Deep Hasura checks"
    echo "**SKIPPED**: HASURA admin secret not loaded."
    echo
    echo "لتفعيل الفحص العميق نفّذ مرة واحدة (بدون ما تكتبه في git):"
    echo '```'
    echo "export HASURA_ADMIN_SECRET='***'"
    echo "./nh_state_report_v2.sh $SUBDOMAIN"
    echo '```'
    exit 0
  fi

  # 1) Inconsistent metadata
  sec "Hasura metadata inconsistencies"
  PAY='{"type":"get_inconsistent_metadata","args":{}}'
  BODY="$(curl_json "$META" "$PAY" 2>/dev/null || true)"
  echo '```'
  printf '%s' "$BODY" | python_json_check >/dev/null && \
  printf '%s' "$BODY" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
incs=d.get("inconsistent_objects",[])
print("inconsistent_objects_count =", len(incs))
for obj in incs[:30]:
  print("-", obj.get("type"), ":", obj.get("reason"))
PY
  echo '```'
  echo

  # 2) export_metadata summary
  sec "Hasura export_metadata summary"
  PAY='{"type":"export_metadata","args":{}}'
  BODY="$(curl_json "$META" "$PAY" 2>/dev/null || true)"
  echo '```'
  printf '%s' "$BODY" | python_json_check >/dev/null && \
  printf '%s' "$BODY" | python3 - <<'PY'
import json,sys
m=json.load(sys.stdin)
sources=m.get("sources",[])
tables=sum(len(s.get("tables",[])) for s in sources)
funcs=sum(len(s.get("functions",[])) for s in sources)
actions=len(m.get("actions",{}).get("actions",[])) if isinstance(m.get("actions"),dict) else 0
events=len(m.get("event_triggers",[])) if isinstance(m.get("event_triggers"),list) else 0
crons=len(m.get("cron_triggers",[])) if isinstance(m.get("cron_triggers"),list) else 0
print("sources:", len(sources))
print("tracked_tables:", tables)
print("tracked_functions:", funcs)
print("actions:", actions)
print("event_triggers:", events)
print("cron_triggers:", crons)
PY
  echo '```'
  echo

  # 3) DB schema listing via run_sql
  sec "DB schema (public/auth/storage tables & views)"
  SQL_TABLES=$(cat <<'SQL'
select n.nspname as schema,
       c.relname as name,
       case c.relkind when 'r' then 'table'
                      when 'v' then 'view'
                      when 'm' then 'mat_view'
                      else c.relkind::text end as kind
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','auth','storage')
  and c.relkind in ('r','v','m')
order by schema, kind, name;
SQL
)
  PAY="$(python3 - <<PY
import json
sql = """$SQL_TABLES"""
print(json.dumps({"type":"run_sql","args":{"source":"default","sql":sql}}))
PY
)"
  BODY="$(curl_json "$META" "$PAY" 2>/dev/null || true)"
  echo '```'
  printf '%s' "$BODY" | python_json_check >/dev/null && \
  printf '%s' "$BODY" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin); res=d.get("result") or []
hdr=res[0]; rows=res[1:]
print("\t".join(hdr))
for r in rows[:500]:
  print("\t".join(map(str,r)))
if len(rows)>500:
  print(f"... ({len(rows)-500} more rows)")
PY
  echo '```'
  echo

  # 4) Key RPC existence/return types
  sec "Key RPCs (existence + return types)"
  SQL_FUNCS=$(cat <<'SQL'
select n.nspname as schema,
       p.proname as name,
       pg_get_function_identity_arguments(p.oid) as args,
       pg_get_function_result(p.oid) as result
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'self_create_account','my_account_plan','my_feature_permissions',
    'create_subscription_request','admin_approve_subscription_request','admin_reject_subscription_request',
    'admin_set_account_plan','expire_account_subscriptions',
    'admin_payment_stats','admin_payment_stats_by_plan','admin_payment_stats_by_day','admin_payment_stats_by_month'
  )
order by p.proname, args;
SQL
)
  PAY="$(python3 - <<PY
import json
sql = """$SQL_FUNCS"""
print(json.dumps({"type":"run_sql","args":{"source":"default","sql":sql}}))
PY
)"
  BODY="$(curl_json "$META" "$PAY" 2>/dev/null || true)"
  echo '```'
  printf '%s' "$BODY" | python_json_check >/dev/null && \
  printf '%s' "$BODY" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin); res=d.get("result") or []
hdr=res[0]; rows=res[1:]
print("\t".join(hdr))
for r in rows:
  print("\t".join(map(str,r)))
PY
  echo '```'
  echo

  # 5) GraphQL sanity (introspection)
  sec "GraphQL sanity (key mutations present?)"
  PAY='{"query":"query { __schema { mutationType { fields { name } } } }"}'
  BODY="$(curl_json "$GQL" "$PAY" 2>/dev/null || true)"
  echo '```'
  printf '%s' "$BODY" | python_json_check >/dev/null && \
  printf '%s' "$BODY" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
fields=[f["name"] for f in d["data"]["__schema"]["mutationType"]["fields"]]
need=["self_create_account","create_subscription_request","admin_approve_subscription_request","admin_reject_subscription_request"]
missing=[x for x in need if x not in fields]
print("mutations_total =", len(fields))
print("missing =", missing)
PY
  echo '```'
) | tee "$OUT" && echo && echo "✅ Saved report: $OUT"
