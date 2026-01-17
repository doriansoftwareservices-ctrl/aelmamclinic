#!/usr/bin/env bash
set -euo pipefail

SUBDOMAIN="${1:-}"
REGION="${2:-}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need nhost; need curl; need python3; need awk

if [[ -z "${SUBDOMAIN}" || -z "${REGION}" ]]; then
  if [[ -f config.json ]]; then
    read -r SUBDOMAIN REGION < <(
      python3 - <<'PY'
import json
with open("config.json", "r", encoding="utf-8") as f:
    cfg = json.load(f)
print(cfg.get("subdomain",""), cfg.get("region",""))
PY
    )
  elif [[ -f .nhost/project.json ]]; then
    read -r SUBDOMAIN REGION < <(
      python3 - <<'PY'
import json
with open(".nhost/project.json", "r", encoding="utf-8") as f:
    cfg = json.load(f)
print(cfg.get("subdomain",""), cfg.get("region",""))
PY
    )
  fi
fi

if [[ -z "${SUBDOMAIN}" || -z "${REGION}" ]]; then
  echo "ERROR: Missing subdomain/region. Provide args or ensure config.json/.nhost/project.json exists." >&2
  exit 2
fi

if [[ -z "${HASURA_GRAPHQL_ADMIN_SECRET:-}" && -n "${HASURA_ADMIN_SECRET:-}" ]]; then
  HASURA_GRAPHQL_ADMIN_SECRET="${HASURA_ADMIN_SECRET}"
fi

if [[ -z "${HASURA_GRAPHQL_ADMIN_SECRET:-}" ]]; then
  read -r -s -p "Paste HASURA_GRAPHQL_ADMIN_SECRET for ${SUBDOMAIN}: " HASURA_GRAPHQL_ADMIN_SECRET
  echo
fi

: "${HASURA_GRAPHQL_ADMIN_SECRET:?ERROR: HASURA_GRAPHQL_ADMIN_SECRET is empty.}"

HASURA_BASE="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run"
META_URL="${HASURA_BASE}/v1/metadata"
RUNSQL_URL="${HASURA_BASE}/v2/query"
GQL_URL="${HASURA_BASE}/v1/graphql"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="server_snapshot_${SUBDOMAIN}_${STAMP}"
REPORT="${OUTDIR}/report.md"
mkdir -p "$OUTDIR"

append() { printf "%s\n" "$*" >> "$REPORT"; }

curl_json_to_file() {
  local url="$1"
  local payload="$2"
  local out="$3"
  local hdr body code
  hdr="$(mktemp)"; body="$(mktemp)"
  if ! curl -sS -D "$hdr" -o "$body" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: ${HASURA_GRAPHQL_ADMIN_SECRET}" \
      -d "$payload" \
      "$url"; then
    cat "$body" > "$out" 2>/dev/null || true
    rm -f "$hdr" "$body"
    return 1
  fi
  code="$(awk 'NR==1{print $2}' "$hdr" 2>/dev/null || true)"
  cat "$body" > "$out"
  rm -f "$hdr" "$body"
  [[ "$code" =~ ^2 ]]
}

run_sql() {
  local sql="$1"
  local out="$2"
  local payload
  payload="$(python3 - <<PY2
import json
print(json.dumps({
  "type":"run_sql",
  "args":{"source":"default","sql": """$sql""", "read_only": True}
}))
PY2
)"
  curl_json_to_file "$RUNSQL_URL" "$payload" "$out"
}

# report header
append "# Server Snapshot (Nhost/Hasura)"
append "- Subdomain: \`$SUBDOMAIN\`"
append "- Region: \`$REGION\`"
append "- Generated: \`$(date -Is)\`"
append "- Output folder: \`$OUTDIR\`"
append ""

append "## Tooling"
append '```'
(nhost version 2>/dev/null || true; python3 --version 2>/dev/null || true) >> "$REPORT"
append '```'
append ""

append "## Nhost config validate"
append '```'
(nhost config validate --subdomain "$SUBDOMAIN" 2>&1 || true) >> "$REPORT"
append '```'
append ""

append "## Secrets (names only)"
append '```'
(nhost secrets list --subdomain "$SUBDOMAIN" 2>&1 || true) >> "$REPORT"
append '```'
append ""

append "## Deployments list"
append '```'
(nhost deployments list --subdomain "$SUBDOMAIN" 2>&1 || true) >> "$REPORT"
append '```'
append ""

# export metadata
META_JSON="${OUTDIR}/hasura_export_metadata.json"
append "## Hasura export_metadata"
if curl_json_to_file "$META_URL" '{"type":"export_metadata","args":{}}' "$META_JSON"; then
  append "Saved: $META_JSON"
else
  append "FAILED: export_metadata"
fi
append ""

# DB inventory
append "## DB inventory"
run_sql "select current_database() as db, version() as postgres_version;" "${OUTDIR}/db_version.json" || true
run_sql "select n.nspname as schema, c.relname as name,
case c.relkind when 'r' then 'table' when 'v' then 'view' when 'm' then 'matview' else c.relkind::text end as kind
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','auth','storage') and c.relkind in ('r','v','m')
order by schema, kind, name;" "${OUTDIR}/db_objects.json" || true
run_sql "select n.nspname as schema, p.proname as name,
pg_get_function_identity_arguments(p.oid) as args,
pg_get_function_result(p.oid) as returns
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','auth','storage')
order by schema, name;" "${OUTDIR}/db_functions.json" || true
run_sql "select schemaname, tablename, policyname, permissive, roles, cmd
from pg_policies
where schemaname in ('public','auth','storage')
order by schemaname, tablename, policyname;" "${OUTDIR}/db_policies.json" || true

append "Saved:"
append "- ${OUTDIR}/db_version.json"
append "- ${OUTDIR}/db_objects.json"
append "- ${OUTDIR}/db_functions.json"
append "- ${OUTDIR}/db_policies.json"
append ""

# GraphQL introspection
GQL_INTRO="${OUTDIR}/graphql_introspection.json"
append "## GraphQL introspection"
if curl_json_to_file "$GQL_URL" '{"query":"query { __schema { queryType { name fields { name } } mutationType { name fields { name } } subscriptionType { name fields { name } } } }"}' "$GQL_INTRO"; then
  append "Saved: $GQL_INTRO"
else
  append "FAILED: GraphQL introspection"
fi
append ""

echo "✅ Done. Snapshot folder: $OUTDIR"
echo "✅ Main report: $REPORT"
