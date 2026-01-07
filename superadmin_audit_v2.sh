#!/usr/bin/env bash
set -euo pipefail

# مهم: قبل التشغيل لازم تكون صادر:
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

echo "== 1) أعمدة auth.users المتاحة =="
run_sql "select column_name,data_type from information_schema.columns where table_schema='auth' and table_name='users' order by column_name;"

echo "== 2) السوبر أدمن في auth.users (بدون roles) =="
run_sql "select id,email,default_role,metadata,app_metadata,raw_app_meta_data,raw_user_meta_data from auth.users where lower(email)=lower('$email');"

echo "== 3) جدول auth.user_roles لهذا المستخدم =="
run_sql "select ur.id,ur.user_id,ur.role,ur.created_at from auth.user_roles ur where ur.user_id = (select id from auth.users where lower(email)=lower('$email') limit 1);"

echo "== 4) هل role=superadmin موجود في auth.roles؟ =="
run_sql "select role from auth.roles where role='superadmin';"
