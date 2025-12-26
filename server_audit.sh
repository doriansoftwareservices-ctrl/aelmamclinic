#!/usr/bin/env bash
set -euo pipefail

SUBDOMAIN="${1:-mergrgclboxflnucehgb}"
TIMEOUT="${TIMEOUT:-30m}"

echo "=============================="
echo "AELMAMCLINIC Server Audit"
echo "Subdomain: $SUBDOMAIN"
echo "=============================="
echo

echo "==[1] Nhost CLI version =="
nhost version || true
echo

echo "==[2] Validate cloud config (Nhost) =="
# Validates the project configuration on cloud
nhost config validate --subdomain "$SUBDOMAIN" || true
echo

echo "==[3] Deployments list =="
nhost deployments list --subdomain "$SUBDOMAIN"
echo

# Try to auto-pick latest deployment UUID from the table output
LATEST_ID="$(nhost deployments list --subdomain "$SUBDOMAIN" | awk 'match($0,/^[0-9a-f-]{36}/){print substr($0,RSTART,RLENGTH); exit}')"

if [[ -n "${LATEST_ID:-}" ]]; then
  echo "==[4] Latest deployment logs (non-follow) =="
  echo "Latest deployment id: $LATEST_ID"
  nhost deployments logs "$LATEST_ID" --subdomain "$SUBDOMAIN" --timeout "$TIMEOUT" || true
else
  echo "==[4] Could not parse latest deployment id from output."
fi
echo

echo "==[5] Cloud secrets (names only) =="
nhost secrets list --subdomain "$SUBDOMAIN" || true
echo

echo "==[6] (Optional) Deep Hasura checks =="
echo "If you export HASURA_ADMIN_SECRET, I'll also check migrations + metadata inconsistencies + key GraphQL mutations."
echo

if [[ -n "${HASURA_ADMIN_SECRET:-}" ]]; then
  REGION="${REGION:-ap-southeast-1}"  # change if your project is in another region
  HASURA_ENDPOINT="https://${SUBDOMAIN}.hasura.${REGION}.nhost.run"

  echo "Hasura endpoint: $HASURA_ENDPOINT"
  echo

  if command -v hasura >/dev/null 2>&1; then
    echo "== Hasura migrations status =="
    hasura migrate status --endpoint "$HASURA_ENDPOINT" --admin-secret "$HASURA_ADMIN_SECRET" --database-name default || true
    echo

    echo "== Hasura metadata inconsistency status/list =="
    hasura metadata inconsistency status --endpoint "$HASURA_ENDPOINT" --admin-secret "$HASURA_ADMIN_SECRET" || true
    hasura metadata inconsistency list   --endpoint "$HASURA_ENDPOINT" --admin-secret "$HASURA_ADMIN_SECRET" || true
    echo
  else
    echo "Hasura CLI not found. Install it first, then re-run:"
    echo "  curl -L https://github.com/hasura/graphql-engine/raw/stable/cli/get.sh | bash"
    echo
  fi

  echo "== GraphQL schema sanity (key mutations) =="
  curl -sS "$HASURA_ENDPOINT/v1/graphql" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
    -d '{"query":"query { __schema { mutationType { fields { name } } } }"}' \
  | python3 - <<'PY'
import json,sys
data=json.load(sys.stdin)
fields=[f["name"] for f in data["data"]["__schema"]["mutationType"]["fields"]]
need=["self_create_account"]
missing=[x for x in need if x not in fields]
print("Mutations found:", len(fields))
if missing:
    print("MISSING:", ", ".join(missing))
    sys.exit(2)
print("OK:", ", ".join(need), "present")
PY

else
  echo "SKIPPED deep checks (HASURA_ADMIN_SECRET not set)."
  echo "To enable deep checks:"
  echo "  export HASURA_ADMIN_SECRET='***'"
  echo "  export REGION='ap-southeast-1'   # only if needed"
  echo "  bash server_audit.sh $SUBDOMAIN"
fi

echo
echo "== Audit completed =="
