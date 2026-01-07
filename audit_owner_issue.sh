#!/usr/bin/env bash
set -euo pipefail

HASURA_BASE="https://mergrgclboxflnucehgb.hasura.ap-southeast-1.nhost.run"
RUNSQL_URL="$HASURA_BASE/v2/query"
email="rdftc35436@elmam.com"

run_sql () {
  local sql="$1"
  local payload
  payload=$(python3 - <<PY
import json
sql = """$sql"""
print(json.dumps({"type":"run_sql","args":{"source":"default","read_only":True,"sql":sql}}))
PY
)
  curl -sS "$RUNSQL_URL" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
    -d "$payload" | python3 -m json.tool
}

echo "== 1) auth.users =="
run_sql "select id,email,default_role,metadata,disabled from auth.users where lower(email)=lower('$email');"

echo "== 2) account_users (كل العضويات) =="
run_sql "select * from public.account_users where user_uid=(select id from auth.users where lower(email)=lower('$email') limit 1) order by created_at desc;"

echo "== 3) profiles =="
run_sql "select * from public.profiles where id=(select id from auth.users where lower(email)=lower('$email') limit 1);"

echo "== 4) user_current_account =="
run_sql "select * from public.user_current_account where user_uid=(select id from auth.users where lower(email)=lower('$email') limit 1);"

echo "== 5) account_subscriptions =="
run_sql "select * from public.account_subscriptions where account_id in (select account_id from public.account_users where user_uid=(select id from auth.users where lower(email)=lower('$email') limit 1)) order by created_at desc;"

echo "== 6) account_feature_permissions =="
run_sql "select * from public.account_feature_permissions where user_uid=(select id from auth.users where lower(email)=lower('$email') limit 1) order by created_at desc;"
