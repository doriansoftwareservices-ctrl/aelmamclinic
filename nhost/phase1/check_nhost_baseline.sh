#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: rg is required." >&2
  exit 2
fi

hardcoded_webhooks_count="$( (rg -n 'webhook:\s*https://[^ ]+\.nhost\.run' nhost/metadata -g '*.yaml' || true) | wc -l | tr -d ' ')"
migration_dirs_count="$(find nhost/migrations/default -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
migration_churn_markers="$(find nhost/migrations/default -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | rg -n 'placeholder|fix|patch|debug|redefine|stub' | wc -l | tr -d ' ')"

metadata_json_exists=0
if [[ -f nhost/metadata.json ]]; then
  metadata_json_exists=1
fi

cron_yaml_count="$( (rg -n '^- name:' nhost/metadata/cron_triggers.yaml 2>/dev/null || true) | wc -l | tr -d ' ')"
cron_json_count="$( (rg -n '"cron_triggers"' nhost/metadata.json 2>/dev/null || true) | wc -l | tr -d ' ')"

echo "NHOST_BASELINE_HARDCODED_WEBHOOKS=$hardcoded_webhooks_count"
echo "NHOST_BASELINE_MIGRATION_DIRS=$migration_dirs_count"
echo "NHOST_BASELINE_MIGRATION_CHURN_MARKERS=$migration_churn_markers"
echo "NHOST_BASELINE_METADATA_JSON_EXISTS=$metadata_json_exists"
echo "NHOST_BASELINE_CRON_YAML_ENTRIES=$cron_yaml_count"
echo "NHOST_BASELINE_CRON_JSON_MARKERS=$cron_json_count"

echo "NHOST_BASELINE_HARDCODED_WEBHOOK_HITS_BEGIN"
rg -n 'webhook:\s*https://[^ ]+\.nhost\.run' \
  nhost/metadata/cron_triggers.yaml \
  nhost/metadata/databases/default/tables/public_chat_messages.yaml \
  nhost/metadata/databases/default/tables/public_patients.yaml \
  nhost/metadata/databases/default/tables/public_subscription_requests.yaml \
  nhost/metadata/databases/default/tables/public_employee_seat_requests.yaml || true
echo "NHOST_BASELINE_HARDCODED_WEBHOOK_HITS_END"
