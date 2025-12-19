#!/usr/bin/env bash
set -euo pipefail

cd /mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic

# 1) Load secrets (must exist already)
set -a
source .secrets
set +a

export HASURA_ENDPOINT='https://plbwpsqxtizkxnqgxgfm.hasura.ap-southeast-1.nhost.run'
export NHOST_ADMIN_SECRET="${HASURA_GRAPHQL_ADMIN_SECRET:?HASURA_GRAPHQL_ADMIN_SECRET missing in .secrets}"
export HASURA_GRAPHQL_ENDPOINT="$HASURA_ENDPOINT/v1/graphql"

echo "[1] Ping Hasura"
curl -sS -X POST "$HASURA_GRAPHQL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
  -d '{"query":"query { __schema { queryType { name } } }"}' | grep -q query_root

echo "[2] Fix effectively-empty SQL files -> SELECT 1;"
python3 - <<'PY'
import pathlib, re
root = pathlib.Path("nhost/migrations/default")
patched = 0
for p in root.rglob("*.sql"):
    txt = p.read_text(encoding="utf-8", errors="ignore").lstrip("\ufeff")
    # remove line comments
    txt2 = re.sub(r'^--.*$', '', txt, flags=re.M)
    # if remaining is only whitespace/semicolons => empty
    if re.sub(r'[\s;]+', '', txt2) == '':
        p.write_text("SELECT 1;\n", encoding="utf-8")
        patched += 1
print(f"patched {patched} files")
PY

echo "[3] Ensure nhost/config.yaml"
cd nhost
test -f config.yaml || cat > config.yaml <<'YAML'
version: 3
metadata_directory: metadata
migrations_directory: migrations
seeds_directory: seeds
YAML

echo "[4] Detect chat_messages create-table migration (if exists)"
CHAT_VER="$(grep -RIn "create table[^(]*chat_messages" migrations/default 2>/dev/null | head -n 1 | sed -E 's#.*/default/([0-9]{14}).*#\1#' || true)"
if [[ -n "${CHAT_VER}" && "${CHAT_VER}" =~ ^[0-9]{14}$ ]]; then
  echo "  -> found chat_messages creator migration version: $CHAT_VER"
  echo "[5] Apply migrations up to chat_messages creator version"
  hasura migrate apply \
    --endpoint "$HASURA_ENDPOINT" \
    --admin-secret "$NHOST_ADMIN_SECRET" \
    --database-name default \
    --version "$CHAT_VER"
else
  echo "  -> no explicit create-table migration for chat_messages found (may be created by different migration name)."
fi

echo "[6] Apply remaining migrations"
hasura migrate apply \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET" \
  --database-name default

echo "[7] Metadata: export (safe) then try apply"
# export gives you a known-good shape from the server
hasura metadata export \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET"

# Try apply from local directory (works if your local metadata structure matches CLI expectations)
# If this fails for you again, you can skip apply and rely on export + console adjustments.
hasura metadata apply \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET" || true

hasura metadata reload \
  --endpoint "$HASURA_ENDPOINT" \
  --admin-secret "$NHOST_ADMIN_SECRET"

echo "[8] Create chat-attachments bucket via SQL (no REST)"
curl -sS -X POST "$HASURA_ENDPOINT/v2/query" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
  -d '{"type":"run_sql","args":{"source":"default","sql":"insert into storage.buckets (id) values (''chat-attachments'') on conflict do nothing;"}}'

echo "[9] Verify chat_messages & buckets"
curl -sS -X POST "$HASURA_ENDPOINT/v2/query" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
  -d '{"type":"run_sql","args":{"source":"default","sql":"select to_regclass(''public.chat_messages'');"}}'

curl -sS -X POST "$HASURA_ENDPOINT/v2/query" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: $NHOST_ADMIN_SECRET" \
  -d '{"type":"run_sql","args":{"source":"default","sql":"select id from storage.buckets order by id;"}}'

echo "DONE"
