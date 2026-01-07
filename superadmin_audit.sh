#!/usr/bin/env bash
set -euo pipefail

# لازم تكون صادر المتغيّر:
# export HASURA_ADMIN_SECRET='...'

HASURA_BASE="https://mergrgclboxflnucehgb.hasura.ap-southeast-1.nhost.run"
RUNSQL_URL="$HASURA_BASE/v2/query"

email="admin.app@elmam.com"

run_sql () {
  local sql="$1"
  local payload
  payload=$(python3 - <<PY
import json
sql = """$sql"""
print(json.dumps({
  "type": "run_sql",
  "args": {
    "source": "default",
    "read_only": True,
    "sql": sql
  }
}))
PY
)
  curl -sS "$RUNSQL_URL" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
    -d "$payload" | python3 -m json.tool
}

echo "== 1) auth.users (السوبر أدمن) =="
run_sql "select id,email,default_role,roles,metadata,app_metadata,raw_app_meta_data,raw_user_meta_data from auth.users where lower(email)=lower('$email');"

echo "== 2) super_admins (هل مسجل كسوبر أدمن؟) =="
run_sql "select id,user_uid,email,created_at from public.super_admins where lower(email)=lower('$email') or user_uid in (select id from auth.users where lower(email)=lower('$email'));"

echo "== 3) تطابق uid + email =="
run_sql "select u.id as user_id,u.email,sa.user_uid as sa_uid,sa.email as sa_email from auth.users u left join public.super_admins sa on sa.user_uid=u.id or lower(sa.email)=lower(u.email) where lower(u.email)=lower('$email');"

echo "== 4) roles المسموحة في auth.roles =="
run_sql "select role from auth.roles where role in ('user','superadmin','anonymous') order by role;"

echo "== 5) فحص uid موجود؟ =="
run_sql "select id,email from auth.users where lower(email)=lower('$email');"
