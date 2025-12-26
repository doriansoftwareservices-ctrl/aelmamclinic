#!/usr/bin/env bash
set -euo pipefail

SUBDOMAIN="${1:-mergrgclboxflnucehgb}"
REGION="${2:-ap-southeast-1}"
TIMEOUT="${TIMEOUT:-30m}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need nhost; need curl; need python3

# Pull secrets locally (needed for Hasura admin secret), but we will NEVER print values
if [ ! -f ".secrets" ] && [ ! -f "secrets" ]; then
  nhost config pull --subdomain "$SUBDOMAIN" >/dev/null 2>&1 || true
fi

# Load secrets file if present
if [ -f ".secrets" ]; then
  set -a; source ./.secrets 2>/dev/null || true; set +a
elif [ -f "secrets" ]; then
  set -a; source ./secrets 2>/dev/null || true; set +a
fi

HASURA_ADMIN_SECRET="${HASURA_ADMIN_SECRET:-${HASURA_GRAPHQL_ADMIN_SECRET:-}}"
if [ -z "${HASURA_ADMIN_SECRET}" ]; then
  echo "ERROR: HASURA_ADMIN_SECRET is empty. Run: nhost config pull --subdomain $SUBDOMAIN (inside project) then retry." >&2
  exit 3
fi

HASURA_BASE="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run"
META_URL="${HASURA_BASE}/v1/metadata"
RUNSQL_URL="${HASURA_BASE}/v2/query"
GQL_URL="${HASURA_BASE}/v1/graphql"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="server_snapshot_${SUBDOMAIN}_${STAMP}"
mkdir -p "$OUTDIR"

REPORT="${OUTDIR}/report.md"
META_JSON="${OUTDIR}/hasura_export_metadata.json"
GQL_INTRO_JSON="${OUTDIR}/graphql_introspection.json"

post_json() {
  local url="$1"
  local payload="$2"
  local out="${3:-/dev/stdout}"

  local hdr body code
  hdr="$(mktemp)"
  body="$(mktemp)"

  if ! curl -sS -D "$hdr" -o "$body" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: ${HASURA_ADMIN_SECRET}" \
      -d "$payload" \
      "$url"; then
    cat "$body" > "$out" 2>/dev/null || true
    echo "HTTP_ERROR curl_failed for $url" >&2
    rm -f "$hdr" "$body"
    return 1
  fi

  code="$(awk 'NR==1{print $2}' "$hdr" 2>/dev/null || true)"
  cat "$body" > "$out" 2>/dev/null || true
  rm -f "$hdr" "$body"

  if [[ -z "$code" || ! "$code" =~ ^2 ]]; then
    echo "HTTP_ERROR ${code:-unknown} for $url" >&2
    return 1
  fi
  return 0
}


run_sql( {
  local sql="$1"
  local out="$2"
  # read_only helps safety; Hasura still treats it as run_sql response
  local payload
  payload="$(python3 - <<PY
import json
print(json.dumps({
  "type":"run_sql",
  "args":{
    "source":"default",
    "sql": """$sql""",
    "read_only": True
  }
}))
PY
)"
  post_json "$RUNSQL_URL" "$payload" "$out"
}

md_section(){ printf "\n## %s\n\n" "$1" >> "$REPORT"; }
md_code(){ printf "```%s\n%s\n```\n\n" "${1:-}" "${2:-}" >> "$REPORT"; }

{
  echo "# Server Snapshot (Nhost/Hasura)"
  echo "- Subdomain: \`$SUBDOMAIN\`"
  echo "- Region: \`$REGION\`"
  echo "- Generated: \`$(date -Is)\`"
  echo "- Output folder: \`$OUTDIR\`"
  echo
} > "$REPORT"

md_section "Tooling versions"
md_code "" "$( (nhost version 2>/dev/null || true; python3 --version 2>/dev/null || true) | sed -e $'s/\r$//' )"

md_section "Nhost config validate"
md_code "" "$(nhost config validate --subdomain "$SUBDOMAIN" 2>&1 || true)"

md_section "Cloud secrets (names only)"
md_code "" "$(nhost secrets list --subdomain "$SUBDOMAIN" 2>&1 || true)"

md_section "Deployments list"
DEP_LIST="$(nhost deployments list --subdomain "$SUBDOMAIN" 2>&1 || true)"
md_code "" "$DEP_LIST"

LATEST_ID="$(printf "%s\n" "$DEP_LIST" | awk '{print $1}' | grep -E "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" | head -n 1 || true)"
md_section "Latest deployment logs"
if [ -n "$LATEST_ID" ]; then
  md_code "" "$(nhost deployments logs "$LATEST_ID" --subdomain "$SUBDOMAIN" --timeout "$TIMEOUT" 2>&1 || true)"
else
  md_code "" "Could not detect latest deployment id from deployments list output."
fi

md_section "Hasura export_metadata (full JSON saved)"
post_json "$META_URL" '{"type":"export_metadata","args":{}}' "$META_JSON" || true
md_code "" "Saved: $META_JSON"

# Metadata summary
md_section "Hasura metadata summary"
md_code "" "$(python3 - <<PY
import json,sys
p="$META_JSON"
try:
  data=json.load(open(p,"r",encoding="utf-8"))
except Exception as e:
  print("Failed to parse hasura_export_metadata.json:", e)
  sys.exit(0)

sources=data.get("sources",[])
tables=0; functions=0; actions=0; remotes=0; cron=0; endpoints=0
for s in sources:
  tables += len(s.get("tables",[]))
  functions += len(s.get("functions",[]))
actions = len(data.get("actions",{}).get("actions",[]) if isinstance(data.get("actions",{}),dict) else data.get("actions",[]))
remotes = len(data.get("remote_schemas",[]))
cron = len(data.get("cron_triggers",[]))
endpoints = len(data.get("rest_endpoints",[]))
print(f"Tracked tables: {tables}")
print(f"Tracked functions: {functions}")
print(f"Actions: {actions}")
print(f"Remote schemas: {remotes}")
print(f"Cron triggers: {cron}")
print(f"REST endpoints: {endpoints}")
PY
)"

# DB inventory via run_sql
md_section "DB inventory (schema objects)"
run_sql "select current_database() as db, version() as postgres_version;" "${OUTDIR}/db_version.json" || true
run_sql "select n.nspname as schema, c.relname as name, case c.relkind when 'r' then 'table' when 'v' then 'view' when 'm' then 'matview' else c.relkind::text end as kind
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','auth','storage')
  and c.relkind in ('r','v','m')
order by schema, kind, name;" "${OUTDIR}/db_objects.json" || true

run_sql "select n.nspname as schema,
       p.proname as name,
       pg_get_function_identity_arguments(p.oid) as args,
       pg_get_function_result(p.oid) as returns,
       p.prokind as kind
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','auth','storage')
order by schema, name;" "${OUTDIR}/db_functions.json" || true

run_sql "select schemaname, tablename, policyname, permissive, roles, cmd
from pg_policies
where schemaname in ('public','auth','storage')
order by schemaname, tablename, policyname;" "${OUTDIR}/db_policies.json" || true

run_sql "select extname, extversion from pg_extension order by extname;" "${OUTDIR}/db_extensions.json" || true

run_sql "select event_object_schema, event_object_table, trigger_name, action_timing, event_manipulation
from information_schema.triggers
where event_object_schema in ('public','auth','storage')
order by event_object_schema, event_object_table, trigger_name;" "${OUTDIR}/db_triggers.json" || true

# Convert key run_sql outputs to TSV (easier to read)
python3 - <<PY
import json,os

def to_tsv(in_path,out_path):
  if not os.path.exists(in_path): return
  try:
    data=json.load(open(in_path,"r",encoding="utf-8"))
  except Exception:
    return
  rows=data.get("result") or []
  if not rows or len(rows)<2: 
    open(out_path,"w",encoding="utf-8").write("")
    return
  with open(out_path,"w",encoding="utf-8") as f:
    for r in rows:
      f.write("\t".join("" if v is None else str(v) for v in r) + "\n")

outdir="$OUTDIR"
to_tsv(os.path.join(outdir,"db_objects.json"), os.path.join(outdir,"db_objects.tsv"))
to_tsv(os.path.join(outdir,"db_functions.json"), os.path.join(outdir,"db_functions.tsv"))
to_tsv(os.path.join(outdir,"db_policies.json"), os.path.join(outdir,"db_policies.tsv"))
to_tsv(os.path.join(outdir,"db_extensions.json"), os.path.join(outdir,"db_extensions.tsv"))
to_tsv(os.path.join(outdir,"db_triggers.json"), os.path.join(outdir,"db_triggers.tsv"))
PY

md_code "" "Saved JSON + TSV:
- ${OUTDIR}/db_objects.(json|tsv)
- ${OUTDIR}/db_functions.(json|tsv)
- ${OUTDIR}/db_policies.(json|tsv)
- ${OUTDIR}/db_extensions.(json|tsv)
- ${OUTDIR}/db_triggers.(json|tsv)
- ${OUTDIR}/db_version.json"

# GraphQL introspection (query/mutation field names)
md_section "GraphQL introspection (query/mutation fields)"
post_json "$GQL_URL" "$(python3 - <<PY
import json
q = "query { __schema { queryType { name fields { name } } mutationType { name fields { name } } subscriptionType { name fields { name } } } }"
print(json.dumps({"query": q}))
PY
)" "$GQL_INTRO_JSON" || true

md_code "" "Saved: $GQL_INTRO_JSON"

md_code "" "$(python3 - <<PY
import json
p="$GQL_INTRO_JSON"
try:
  data=json.load(open(p,"r",encoding="utf-8"))
  s=data.get("data",{}).get("__schema",{})
  qt=s.get("queryType") or {}
  mt=s.get("mutationType") or {}
  qf=qt.get("fields") or []
  mf=mt.get("fields") or []
  print(f"query_root fields: {len(qf)}")
  print(f"mutation_root fields: {len(mf)}")
  # show a small sample
  print("\\nSample query fields:")
  for n in [x.get("name") for x in qf[:40]]:
    print(" -", n)
  print("\\nSample mutation fields:")
  for n in [x.get("name") for x in mf[:40]]:
    print(" -", n)
except Exception as e:
  print("Failed to parse introspection:", e)
PY
)"

echo "✅ Done. Snapshot folder: $OUTDIR"
echo "✅ Main report: $REPORT"
