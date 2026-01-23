#!/usr/bin/env bash
set -euo pipefail

if ! command -v nhost >/dev/null 2>&1; then
  echo "nhost CLI not found. Install it, then re-run." >&2
  exit 1
fi

if [ -z "${HASURA_GRAPHQL_ADMIN_SECRET:-}" ]; then
  read -r -s -p "HASURA_GRAPHQL_ADMIN_SECRET: " HASURA_GRAPHQL_ADMIN_SECRET
  echo
  export HASURA_GRAPHQL_ADMIN_SECRET
fi

# Apply metadata from nhost/metadata to the configured project.
nhost metadata apply --admin-secret "${HASURA_GRAPHQL_ADMIN_SECRET}"

# If you want a forced reload, run:
# curl -sS -X POST "${NHOST_HASURA_URL:-https://<subdomain>.hasura.<region>.nhost.run}/v1/metadata" \
#   -H "Content-Type: application/json" \
#   -H "x-hasura-admin-secret: ${HASURA_GRAPHQL_ADMIN_SECRET}" \
#   --data-binary '{"type":"reload_metadata","args":{}}'
