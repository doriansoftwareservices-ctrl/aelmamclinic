#!/usr/bin/env bash
set -euo pipefail

PROJECT="/mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic"
ROOT="$PROJECT/nhost/migrations/default"

cd "$PROJECT"
set -a; source .secrets; set +a

export HASURA_ENDPOINT='https://plbwpsqxtizkxnqgxgfm.hasura.ap-southeast-1.nhost.run'
export NHOST_ADMIN_SECRET="${HASURA_GRAPHQL_ADMIN_SECRET:?HASURA_GRAPHQL_ADMIN_SECRET missing}"
export HASURA_GRAPHQL_ENDPOINT="$HASURA_ENDPOINT/v1/graphql"

run_sql () {
  local sql="$1"
  RUNSQL="$sql" python3 - <<'PY' | curl -sS -X POST "$HASURA_ENDPOINT/v2/query" \
    -H "Content-Type: application/json" \
    -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
    --data-binary @-
import json, os
print(json.dumps({"type":"run_sql","args":{"source":"default","sql":os.environ["RUNSQL"]}}))
PY
  echo
}

echo "==[1] Ping GraphQL =="
curl -sS -X POST "$HASURA_GRAPHQL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
  -d '{"query":"query { __schema { queryType { name } } }"}' | grep -q query_root

echo "==[2] Fix request_uid_text(): force RETURNS uuid (DROP then CREATE) =="
run_sql "DROP FUNCTION IF EXISTS public.request_uid_text();"
run_sql "CREATE OR REPLACE FUNCTION public.request_uid_text()
RETURNS uuid
LANGUAGE sql
STABLE
AS \$\$
  SELECT NULLIF(
    COALESCE(
      current_setting('hasura.user', true)::json ->> 'x-hasura-user-id',
      current_setting('request.jwt.claims', true)::json ->> 'sub'
    ),
    ''
  )::uuid;
\$\$;"

echo "==[3] Ensure supabase_realtime publication exists (idempotent) =="
run_sql "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    EXECUTE 'CREATE PUBLICATION supabase_realtime';
  END IF;
END \$\$;"

echo "==[4] Patch migrations for Nhost (roles/auth/storage/uuid) =="

python3 - <<'PY'
import re, pathlib

root = pathlib.Path("nhost/migrations/default")
files = list(root.rglob("*.sql"))

def read(p): return p.read_text(encoding="utf-8", errors="ignore").lstrip("\ufeff")
def write(p,s): p.write_text(s, encoding="utf-8")

patched = 0

# 4.1) لا تعتمد على DB roles غير موجودة (authenticated/service_role) -> public
re_to_role = re.compile(r'\bTO\s+(authenticated|service_role)\b', re.IGNORECASE)
re_grant_to_role = re.compile(r'(\bgrant\b.*?\bto\s+)(authenticated|service_role)\b', re.IGNORECASE)

# 4.2) auth.jwt/auth.uid (Supabase) -> بدائل لا تحتاج schema auth
# - auth.uid() -> public.request_uid_text()
# - auth.jwt()->>'x' -> current_setting('request.jwt.claims', true)::json ->> 'x'
re_auth_uid = re.compile(r'\bauth\.uid\s*\(\s*\)', re.IGNORECASE)
re_auth_jwt_key = re.compile(r"auth\.jwt\s*\(\s*\)\s*->>\s*'([^']+)'", re.IGNORECASE)

# 4.3) تأكيد المقارنات: = public.request_uid_text() بدون cast (لو بقيت) -> ::uuid
re_eq_request_uid = re.compile(r'=\s*public\.request_uid_text\(\)\b(?!\s*::uuid)', re.IGNORECASE)

# 4.4) storage.buckets: عمود public غير موجود عندك -> إزالة أي INSERT/UPDATE يستخدمه
re_insert_buckets_public = re.compile(
    r"INSERT\s+INTO\s+storage\.buckets\s*\(\s*id\s*,\s*name\s*,\s*public\s*\)\s*VALUES\s*\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)\s*;?",
    re.IGNORECASE
)
re_update_buckets_public = re.compile(
    r"UPDATE\s+storage\.buckets\s+SET\s+public\s*=\s*(true|false)\s+WHERE\s+id\s*=\s*'([^']+)'\s*;?",
    re.IGNORECASE
)

# 4.5) أي هجرة تتعامل مع storage.objects: أضف guard إن لم تكن موجودة
def guard_storage_objects(txt: str) -> str:
    if "storage.objects" not in txt:
        return txt
    if "to_regclass('storage.objects')" in txt:
        return txt
    m = re.search(r'\bDO\s+\$\$|\bDO\s+\$[a-zA-Z_]+\$|\bBEGIN\b', txt)
    if not m:
        return txt
    # نضيف بعد أول BEGIN (حل عملي)
    mb = re.search(r'\bBEGIN\b', txt)
    if not mb:
        return txt
    ins = (
        "BEGIN\n"
        "  IF to_regclass('storage.objects') IS NULL THEN\n"
        "    RAISE NOTICE 'storage.objects not found; skipping storage.objects changes';\n"
        "    RETURN;\n"
        "  END IF;\n"
    )
    return txt[:mb.start()] + ins + txt[mb.end():]

for p in files:
    txt = read(p)
    orig = txt

    txt = re_to_role.sub("TO public", txt)
    txt = re_grant_to_role.sub(lambda m: m.group(1) + "public", txt)

    txt = re_auth_uid.sub("public.request_uid_text()", txt)
    txt = re_auth_jwt_key.sub(lambda m: "current_setting('request.jwt.claims', true)::json ->> '" + m.group(1) + "'", txt)

    txt = re_eq_request_uid.sub("= public.request_uid_text()::uuid", txt)

    txt = re_insert_buckets_public.sub(lambda m: f"INSERT INTO storage.buckets (id, name) VALUES ('{m.group(1)}', '{m.group(2)}') ON CONFLICT (id) DO NOTHING;", txt)
    txt = re_update_buckets_public.sub(lambda m: f"-- patched: storage.buckets has no column public in Nhost; skipped update for bucket '{m.group(2)}'.", txt)

    txt = guard_storage_objects(txt)

    # إذا ملف صار فارغ فعليًا
    stripped = re.sub(r'^--.*$', '', txt, flags=re.M).strip().strip(';').strip()
    if stripped == "":
        txt = "SELECT 1;\n"

    if txt != orig:
        write(p, txt)
        patched += 1

print(f"patched_files={patched}")
PY

echo "==[5] Apply migrations =="
cd "$PROJECT/nhost"
hasura migrate apply \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET" \
  --database-name default

echo "==[6] Apply+reload metadata =="
if [ -f metadata/metadata.json ] && [ ! -f metadata/metadata.yaml ]; then
  cp metadata/metadata.json metadata/metadata.yaml
fi

hasura metadata apply \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET"

hasura metadata reload \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET"

echo "==[7] Status =="
hasura migrate status \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET" \
  --database-name default | head -n 160

echo "DONE ✅"
