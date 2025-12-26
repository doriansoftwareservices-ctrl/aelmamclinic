#!/usr/bin/env bash
set -euo pipefail
SUBDOMAIN="${1:-mergrgclboxflnucehgb}"
TIMEOUT="${TIMEOUT:-30m}"

echo "== Nhost CLI version =="
nhost sw version 2>/dev/null || nhost --version 2>/dev/null || true
echo

echo "== Validate cloud config =="
nhost config validate --subdomain "$SUBDOMAIN" || true
echo

echo "== Deployments list =="
nhost deployments list --subdomain "$SUBDOMAIN"
echo

LATEST_ID="$(nhost deployments list --subdomain "$SUBDOMAIN" \
  | grep -Eo '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' \
  | head -n 1)"

echo "== Latest deployment logs (full) =="
echo "latest_id=$LATEST_ID"
nhost deployments logs "$LATEST_ID" --subdomain "$SUBDOMAIN" --timeout "$TIMEOUT" || true
echo

echo "== If latest FAILED, show previous FAILED too (up to 2) =="
mapfile -t FAIL_IDS < <(nhost deployments list --subdomain "$SUBDOMAIN" \
  | awk '/FAILED/ {print $1}' | head -n 2)

for id in "${FAIL_IDS[@]:-}"; do
  echo
  echo "---- FAILED deployment logs: $id ----"
  nhost deployments logs "$id" --subdomain "$SUBDOMAIN" --timeout "$TIMEOUT" || true
done

echo
echo "== Secrets (names) =="
nhost secrets list --subdomain "$SUBDOMAIN" || true

echo
echo "== Done =="
