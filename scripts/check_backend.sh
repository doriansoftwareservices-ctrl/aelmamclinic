#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "==[0] Load secrets =="
set -a
source .secrets
set +a

GQL_FROM_CONFIG="$(
python3 - <<'PY'
import json
d=json.load(open("config.json","r",encoding="utf-8"))
print(d.get("nhostGraphqlUrl","").strip())
PY
)"

AUTH_FROM_CONFIG="$(
python3 - <<'PY'
import json
d=json.load(open("config.json","r",encoding="utf-8"))
print(d.get("nhostAuthUrl","").strip())
PY
)"

SUBDOMAIN="plbwpsqxtizkxnqgxgfm"
REGION="ap-southeast-1"
GRAPHQL_URL="${GQL_FROM_CONFIG:-https://${SUBDOMAIN}.graphql.${REGION}.nhost.run/v1}"
AUTH_URL="${AUTH_FROM_CONFIG:-https://${SUBDOMAIN}.auth.${REGION}.nhost.run/v1}"
GRAPHQL_ADMIN_URL="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run/v1/graphql"
META_URL="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run/v1/metadata"
RUNSQL_URL="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run/v2/query"

ADMIN_SECRET="$(printf %s "${HASURA_GRAPHQL_ADMIN_SECRET:-}" | tr -d '\r')"
if [[ -z "$ADMIN_SECRET" ]]; then
  echo "ERROR: HASURA_GRAPHQL_ADMIN_SECRET missing"
  exit 1
fi

echo "GraphQL: $GRAPHQL_URL"
echo "GraphQL(Admin): $GRAPHQL_ADMIN_URL"
echo "Auth:    $AUTH_URL"
echo "Meta:    $META_URL"
echo "RunSQL:  $RUNSQL_URL"
echo

echo "==[1] DNS check =="
for host in \
  "${SUBDOMAIN}.graphql.${REGION}.nhost.run" \
  "${SUBDOMAIN}.auth.${REGION}.nhost.run" \
  "${SUBDOMAIN}.hasura.${REGION}.nhost.run"
do
  echo "- $host"
  getent ahosts "$host" | head -n 1 || true
done
echo

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_gql() {
  local payload="$1"
  local out="${2:-$TMP_DIR/resp.json}"
  curl -sS -D "$TMP_DIR/resp.headers" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $ADMIN_SECRET" \
    --data-binary @"$payload" \
    "$GRAPHQL_ADMIN_URL" > "$out"
  if [[ ! -s "$out" ]]; then
    echo "ERROR: empty response from GraphQL admin endpoint: $GRAPHQL_ADMIN_URL" >&2
    sed -n '1,5p' "$TMP_DIR/resp.headers" >&2
    exit 1
  fi
  python3 - <<'PY' "$out" >/dev/null 2>&1
import json,sys
json.load(open(sys.argv[1],"r",encoding="utf-8"))
PY
  if [[ "$?" -ne 0 ]]; then
    echo "ERROR: non-JSON response from GraphQL admin endpoint: $GRAPHQL_ADMIN_URL" >&2
    sed -n '1,5p' "$TMP_DIR/resp.headers" >&2
    head -n 5 "$out" >&2
    exit 1
  fi
}

run_gql_role() {
  local payload="$1"
  local out="${2:-$TMP_DIR/resp.json}"
  local role="$3"
  curl -sS -D "$TMP_DIR/resp.headers" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $ADMIN_SECRET" \
    -H "x-hasura-role: $role" \
    --data-binary @"$payload" \
    "$GRAPHQL_ADMIN_URL" > "$out"
  if [[ ! -s "$out" ]]; then
    echo "ERROR: empty response from GraphQL admin endpoint: $GRAPHQL_ADMIN_URL" >&2
    sed -n '1,5p' "$TMP_DIR/resp.headers" >&2
    exit 1
  fi
  python3 - <<'PY' "$out" >/dev/null 2>&1
import json,sys
json.load(open(sys.argv[1],"r",encoding="utf-8"))
PY
  if [[ "$?" -ne 0 ]]; then
    echo "ERROR: non-JSON response from GraphQL admin endpoint: $GRAPHQL_ADMIN_URL" >&2
    sed -n '1,5p' "$TMP_DIR/resp.headers" >&2
    head -n 5 "$out" >&2
    exit 1
  fi
}

print_errors_if_any() {
  local file="$1"
  python3 - <<'PY' "$file"
import json,sys
data=json.load(open(sys.argv[1],"r",encoding="utf-8"))
if "errors" in data:
    print("GraphQL errors:", data["errors"])
if "data" not in data:
    raise SystemExit(1)
PY
}

run_meta() {
  local payload="$1"
  local out="${2:-$TMP_DIR/meta.resp}"
  curl -sS -D "$TMP_DIR/meta.headers" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $ADMIN_SECRET" \
    --data-binary @"$payload" \
    "$META_URL" > "$out"
  if [[ ! -s "$out" ]]; then
    echo "ERROR: empty response from Hasura metadata endpoint: $META_URL" >&2
    sed -n '1,5p' "$TMP_DIR/meta.headers" >&2
    exit 1
  fi
  python3 - <<'PY' "$out" >/dev/null 2>&1
import json,sys
json.load(open(sys.argv[1],"r",encoding="utf-8"))
PY
  if [[ "$?" -ne 0 ]]; then
    echo "ERROR: non-JSON response from Hasura metadata endpoint: $META_URL" >&2
    sed -n '1,5p' "$TMP_DIR/meta.headers" >&2
    head -n 5 "$out" >&2
    exit 1
  fi
}

run_sql() {
  local payload="$1"
  local out="${2:-$TMP_DIR/sql.resp}"
  curl -sS -D "$TMP_DIR/sql.headers" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $ADMIN_SECRET" \
    --data-binary @"$payload" \
    "$RUNSQL_URL" > "$out"
  if [[ ! -s "$out" ]]; then
    echo "ERROR: empty response from Hasura run_sql endpoint: $RUNSQL_URL" >&2
    sed -n '1,5p' "$TMP_DIR/sql.headers" >&2
    exit 1
  fi
  python3 - <<'PY' "$out" >/dev/null 2>&1
import json,sys
json.load(open(sys.argv[1],"r",encoding="utf-8"))
PY
  if [[ "$?" -ne 0 ]]; then
    echo "ERROR: non-JSON response from Hasura run_sql endpoint: $RUNSQL_URL" >&2
    sed -n '1,5p' "$TMP_DIR/sql.headers" >&2
    head -n 5 "$out" >&2
    exit 1
  fi
}

SCHEMA_ROLE="superadmin"
echo "==[2] Admin schema check (critical functions) for role: $SCHEMA_ROLE =="
cat > "$TMP_DIR/query_fields.json" <<'JSON'
{"query":"query { __schema { queryType { fields { name } } } }"}
JSON
run_gql_role "$TMP_DIR/query_fields.json" "$TMP_DIR/query_fields.resp" "$SCHEMA_ROLE"
print_errors_if_any "$TMP_DIR/query_fields.resp" || {
  echo "ERROR: query schema response (raw):"
  cat "$TMP_DIR/query_fields.resp"
  exit 1
}
python3 - <<'PY' "$TMP_DIR/query_fields.resp"
import json,sys
data=json.load(open(sys.argv[1],"r",encoding="utf-8"))
names=[f["name"] for f in data["data"]["__schema"]["queryType"]["fields"]]
need=[
  "fn_is_super_admin_gql",
  "admin_list_clinics",
  "list_employees_with_email",
  "my_feature_permissions",
  "my_account_id",
  "my_profile"
]
missing=[n for n in need if n not in names]
print("Missing queries:", missing if missing else "none")
PY
echo

cat > "$TMP_DIR/mutation_fields.json" <<'JSON'
{"query":"query { __schema { mutationType { fields { name } } } }"}
JSON
run_gql_role "$TMP_DIR/mutation_fields.json" "$TMP_DIR/mutation_fields.resp" "$SCHEMA_ROLE"
print_errors_if_any "$TMP_DIR/mutation_fields.resp" || {
  echo "ERROR: mutation schema response (raw):"
  cat "$TMP_DIR/mutation_fields.resp"
  exit 1
}
python3 - <<'PY' "$TMP_DIR/mutation_fields.resp"
import json,sys
data=json.load(open(sys.argv[1],"r",encoding="utf-8"))
mutation_type = data["data"]["__schema"].get("mutationType")
if not mutation_type:
    print("Missing mutations: (none, mutationType is null)")
    raise SystemExit(0)
names=[f["name"] for f in mutation_type["fields"]]
need=[
  "admin_create_owner_full",
  "admin_create_employee_full",
  "admin_set_clinic_frozen",
  "admin_delete_clinic",
  "set_employee_disabled",
  "delete_employee",
  "chat_accept_invitation",
  "chat_decline_invitation",
  "chat_mark_delivered"
]
missing=[n for n in need if n not in names]
print("Missing mutations:", missing if missing else "none")
PY
echo

echo "==[2.1] Tracked functions in metadata (server) =="
cat > "$TMP_DIR/export_meta.json" <<'JSON'
{"type":"export_metadata","args":{}}
JSON
run_meta "$TMP_DIR/export_meta.json" "$TMP_DIR/export_meta.resp"
python3 - <<'PY' "$TMP_DIR/export_meta.resp"
import json,sys
data=json.load(open(sys.argv[1],"r",encoding="utf-8"))
sources=data.get("sources") or data.get("metadata",{}).get("sources") or []
funcs=(sources[0].get("functions") if sources else []) or []
names=[f.get("function",{}).get("name") for f in funcs if isinstance(f, dict)]
names=[n for n in names if n]
print("Tracked functions:", sorted(names))
PY
echo

echo "==[2.2] Function volatility (server) =="
cat > "$TMP_DIR/volatility.json" <<'JSON'
{"type":"run_sql","args":{"source":"default","sql":"select proname, provolatile from pg_proc join pg_namespace n on n.oid=pg_proc.pronamespace where n.nspname='public' and proname in ('admin_list_clinics','list_employees_with_email','my_feature_permissions','my_account_id','my_profile','admin_create_owner_full','admin_create_employee_full','admin_set_clinic_frozen','admin_delete_clinic','set_employee_disabled','delete_employee');"}}
JSON
run_sql "$TMP_DIR/volatility.json" "$TMP_DIR/volatility.resp"
python3 - <<'PY' "$TMP_DIR/volatility.resp"
import json,sys
data=json.load(open(sys.argv[1],"r",encoding="utf-8"))
rows=data.get("result", [])
for row in rows:
  print("\t".join(row))
PY
echo

echo "==[3] Super admin rows =="
cat > "$TMP_DIR/super_admins.json" <<'JSON'
{"query":"query { super_admins { email user_uid } }"}
JSON
run_gql "$TMP_DIR/super_admins.json" "$TMP_DIR/super_admins.resp"
cat "$TMP_DIR/super_admins.resp"
echo
echo

echo "==[4] JWT test (Super Admin) =="
EMAIL="${CHECKBACKEND_EMAIL:-admin@elmam.com}"
PASS="${CHECKBACKEND_PASSWORD:-aelmam@6069}"

SESSION_FILE="/tmp/session.json"
rm -f "$SESSION_FILE"

curl -sS --connect-timeout 20 -m 60 \
  --retry 6 --retry-delay 2 --retry-all-errors \
  -H "Content-Type: application/json" \
  --data-binary "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  "$AUTH_URL/signin/email-password" > "$SESSION_FILE"

TOKEN="$(
python3 - <<'PY'
import json
d=json.load(open("/tmp/session.json","r",encoding="utf-8"))
print(d["session"]["accessToken"])
PY
)"

echo "TOKEN_LEN=${#TOKEN}"
echo

echo "==[5] fn_is_super_admin_gql (boolean) with JWT =="
cat > "$TMP_DIR/super_gql.json" <<'JSON'
{"query":"query { fn_is_super_admin_gql { is_super_admin } }"}
JSON
curl -sS \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-hasura-role: me" \
  --data-binary @"$TMP_DIR/super_gql.json" \
  "$GRAPHQL_URL"
echo
echo

echo "==[DONE] Report ready =="
