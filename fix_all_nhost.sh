#!/usr/bin/env bash
set -euo pipefail

PROJECT="/mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic"
ROOT="$PROJECT/nhost/migrations/default"

cd "$PROJECT"

echo "==[0] Load secrets + endpoints =="
set -a; source .secrets; set +a
export HASURA_ENDPOINT='https://mergrgclboxflnucehgb.hasura.ap-southeast-1.nhost.run'
export NHOST_ADMIN_SECRET="${HASURA_GRAPHQL_ADMIN_SECRET:?HASURA_GRAPHQL_ADMIN_SECRET missing}"
export HASURA_GRAPHQL_ENDPOINT="$HASURA_ENDPOINT/v1/graphql"

run_sql () {
  local sql="$1"
  RUNSQL="$sql" python3 - <<'PY' | curl -sS -X POST "$HASURA_ENDPOINT/v2/query" \
    -H "Content-Type: application/json" \
    -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
    --data-binary @-
import json, os
print(json.dumps({
  "type": "run_sql",
  "args": {"source": "default", "sql": os.environ["RUNSQL"]}
}))
PY
}

echo "==[1] Ping Hasura GraphQL =="
curl -sS -X POST "$HASURA_GRAPHQL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
  -d '{"query":"query { __schema { queryType { name } } }"}' | grep -q query_root

echo "==[2] DB compatibility layer =="
# 2.1 request_uid_text(): tolerate non-JSON session values (returns text)
run_sql "$(cat <<'SQL'
CREATE OR REPLACE FUNCTION public.request_uid_text()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  uid_text text;
  uid_regex text;
BEGIN
  IF raw_hasura_user IS NOT NULL AND raw_hasura_user <> '' THEN
    BEGIN
      hasura_user := raw_hasura_user::jsonb;
    EXCEPTION WHEN others THEN
      hasura_user := '{}'::jsonb;
    END;
  END IF;

  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  uid_text := NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.sub', true),
      current_setting('request.jwt.claim.x-hasura-user-id', true)
    ),
    ''
  );

  IF uid_text IS NULL THEN
    uid_text := COALESCE(
      hasura_user ->> 'x-hasura-user-id',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
      claims ->> 'x-hasura-user-id',
      claims ->> 'sub'
    );
  END IF;

  IF uid_text IS NULL AND raw_hasura_user IS NOT NULL THEN
    uid_regex := regexp_replace(
      raw_hasura_user,
      '.*\"x-hasura-user-id\"\\s*:\\s*\"([^\"]+)\".*',
      '\\1'
    );
    IF uid_regex IS NOT NULL AND uid_regex <> raw_hasura_user THEN
      uid_text := uid_regex;
    END IF;
  END IF;

  IF uid_text IS NULL AND raw_claims IS NOT NULL THEN
    uid_regex := regexp_replace(
      raw_claims,
      '.*\"x-hasura-user-id\"\\s*:\\s*\"([^\"]+)\".*',
      '\\1'
    );
    IF uid_regex IS NOT NULL AND uid_regex <> raw_claims THEN
      uid_text := uid_regex;
    END IF;
  END IF;

  RETURN NULLIF(uid_text, '');
END;
$$;
SQL
)"

# 2.2 auth.jwt/auth.uid توافق لسوبابيز
run_sql "CREATE SCHEMA IF NOT EXISTS auth;"

run_sql "CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS \$\$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb,
    NULLIF(current_setting('hasura.user', true), '')::jsonb,
    '{}'::jsonb
  );
\$\$;"

run_sql "CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS \$\$
  SELECT public.request_uid_text();
\$\$;"

# 2.3 publication supabase_realtime (للهجرات التي تعدّلها)
run_sql "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    EXECUTE 'CREATE PUBLICATION supabase_realtime';
  END IF;
END \$\$;"

# 2.4 تأكيد نوع الدالة (مهم!)
echo "==[2.4] Verify request_uid_text() type =="
run_sql "select pg_typeof(public.request_uid_text());"

echo "==[3] Patch migrations for Nhost compatibility =="
python3 - <<'PY'
import re, pathlib

root = pathlib.Path("nhost/migrations/default")
sql_files = list(root.rglob("*.sql"))

def read(p): return p.read_text(encoding="utf-8", errors="ignore").lstrip("\ufeff")
def write(p,s): p.write_text(s, encoding="utf-8")

grant_to_role = re.compile(r'(\bgrant\b.*?\bto\s+)(authenticated|service_role)\b', re.IGNORECASE)
role_to_public = [
    (re.compile(r'\bTO\s+authenticated\b', re.IGNORECASE), 'TO public'),
    (re.compile(r'\bTO\s+service_role\b', re.IGNORECASE), 'TO public'),
    (re.compile(r'\bto\s+authenticated\b', re.IGNORECASE), 'to public'),
    (re.compile(r'\bto\s+service_role\b', re.IGNORECASE), 'to public'),
]

# storage.buckets public column (غير موجود عندك سابقاً)
insert_buckets_public = re.compile(
    r"INSERT\s+INTO\s+storage\.buckets\s*\(\s*id\s*,\s*name\s*,\s*public\s*\)\s*VALUES\s*\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)\s*;?",
    re.IGNORECASE
)
update_buckets_public = re.compile(
    r"UPDATE\s+storage\.buckets\s+SET\s+public\s*=\s*(true|false)\s+WHERE\s+id\s*=\s*'([^']+)'\s*;?",
    re.IGNORECASE
)

def ensure_storage_objects_guard(txt: str) -> str:
    if "storage.objects" not in txt:
        return txt
    if "to_regclass('storage.objects')" in txt:
        return txt
    m = re.search(r'\bBEGIN\b', txt)
    if not m:
        return txt
    insert = (
        "BEGIN\n"
        "  IF to_regclass('storage.objects') IS NULL THEN\n"
        "    RAISE NOTICE 'storage.objects not found; skipping storage.objects policy changes';\n"
        "    RETURN;\n"
        "  END IF;\n"
    )
    return txt[:m.start()] + insert + txt[m.end():]

patched = 0
for p in sql_files:
    txt = read(p)
    orig = txt

    # roles -> public
    for rgx, repl in role_to_public:
        txt = rgx.sub(repl, txt)
    txt = grant_to_role.sub(lambda m: m.group(1) + "public", txt)

    # buckets public -> (id,name)
    txt = insert_buckets_public.sub(
        lambda m: f"INSERT INTO storage.buckets (id, name) VALUES ('{m.group(1)}', '{m.group(2)}') ON CONFLICT (id) DO NOTHING;",
        txt
    )
    txt = update_buckets_public.sub(
        lambda m: f\"-- patched: storage.buckets has no column public in Nhost; skipped UPDATE public for bucket '{m.group(2)}'.\",
        txt
    )

    # guard storage.objects
    txt = ensure_storage_objects_guard(txt)

    # empty SQL safety
    stripped = re.sub(r'^--.*$', '', txt, flags=re.M).strip().strip(';').strip()
    if stripped == "":
        txt = "SELECT 1;\n"

    if txt != orig:
        write(p, txt)
        patched += 1

print(f"patched_files={patched}")
PY

echo "==[4] Apply remaining migrations =="
cd "$PROJECT/nhost"
hasura migrate apply \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET" \
  --database-name default

echo "==[5] Apply + reload metadata =="
if [ -f metadata/metadata.json ] && [ ! -f metadata/metadata.yaml ]; then
  cp metadata/metadata.json metadata/metadata.yaml
fi

hasura metadata apply \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET"

hasura metadata reload \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET"

echo "==[6] Status (first 120 lines) =="
hasura migrate status \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET" \
  --database-name default | head -n 120

echo "DONE ✅"
