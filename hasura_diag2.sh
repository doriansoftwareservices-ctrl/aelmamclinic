set -euo pipefail

SUB="ujxbrdbrjbujvlylpbbn"
REG="ap-southeast-1"
HASURA_V2="https://${SUB}.hasura.${REG}.nhost.run/v2/query"

ACCOUNT_ID="d37599c0-b845-42b0-9e56-5a5dc07d77f1"
USER_UID="0601cd24-fa91-4521-97a6-9a4d10202540"

read -r -s -p "HASURA_GRAPHQL_ADMIN_SECRET: " HASURA_GRAPHQL_ADMIN_SECRET; echo

run_sql_ro () {
  local sql="$1"
  python3 - <<PY | curl -sS -X POST "$HASURA_V2" \
    -H "x-hasura-admin-secret: ${HASURA_GRAPHQL_ADMIN_SECRET}" \
    -H "content-type: application/json" \
    --data-binary @- | python3 -m json.tool
import json
print(json.dumps({"type":"run_sql","args":{"source":"default","read_only":True,"sql":"""$sql"""}}))
PY
}

run_sql_rw () {
  local sql="$1"
  python3 - <<PY | curl -sS -X POST "$HASURA_V2" \
    -H "x-hasura-admin-secret: ${HASURA_GRAPHQL_ADMIN_SECRET}" \
    -H "content-type: application/json" \
    --data-binary @- | python3 -m json.tool
import json
print(json.dumps({"type":"run_sql","args":{"source":"default","read_only":False,"sql":"""$sql"""}}))
PY
}

echo "=== 0) employees columns (confirm schema) ==="
run_sql_ro "select ordinal_position, column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='employees'
order by ordinal_position;"

echo
echo "=== 1) employee row for this user ==="
run_sql_ro "select id, account_id, user_uid, is_doctor, created_at, updated_at
from public.employees
where account_id='${ACCOUNT_ID}' and user_uid='${USER_UID}'
limit 10;"

echo
echo "=== 2) subscriptions for this account ==="
run_sql_ro "select account_id, plan_code, status, start_at, end_at, created_at
from public.account_subscriptions
where account_id='${ACCOUNT_ID}'
order by created_at desc
limit 20;"

echo
echo "=== 3) quick check: active month/year exists? ==="
run_sql_ro "select count(*) as active_month_year
from public.account_subscriptions
where account_id='${ACCOUNT_ID}'
  and status ilike 'active'
  and plan_code in ('month','year');"

echo
echo "=== OPTIONAL: enable is_doctor (run ONLY if is_doctor=false and row exists) ==="
echo "If needed, run this command manually:"
echo 'bash -lc '"'"'source <(sed -n "1,999p" hasura_diag2.sh); run_sql_rw "update public.employees set is_doctor=true, updated_at=now() where account_id='\'''"${ACCOUNT_ID}"'\'' and user_uid='\'''"${USER_UID}"'\'';"'"'"
