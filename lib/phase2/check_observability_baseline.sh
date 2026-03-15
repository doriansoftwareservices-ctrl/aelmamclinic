#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: rg is required." >&2
  exit 2
fi

critical_files=(
  "lib/main.dart"
  "lib/providers/auth_provider.dart"
  "lib/providers/chat_provider.dart"
  "lib/services/push_notifications_service.dart"
  "lib/services/sync_service.dart"
  "lib/services/db_service.dart"
)

silent_catch_count="$( (rg -n 'catch \(_\)' "${critical_files[@]}" || true) | wc -l | tr -d ' ' )"
structured_obs_count="$( (rg -n 'AppObservability|ObsCode|_authObsWarn|_chatWarn|_pushWarn|_syncWarn|_dbWarn' "${critical_files[@]}" lib/utils/app_observability.dart || true) | wc -l | tr -d ' ' )"
global_error_hook_count="$( (rg -n 'ObsCode\.appFlutterError|ObsCode\.appZonedError' lib/main.dart || true) | wc -l | tr -d ' ' )"
runtime_summary_script_count="$( (rg -n 'app_runtime_events\.jsonl|json' lib/phase2/summarize_runtime_events.sh || true) | wc -l | tr -d ' ' )"

echo "OBS_BASELINE_CRITICAL_SILENT_CATCHES=$silent_catch_count"
echo "OBS_BASELINE_STRUCTURED_USAGE=$structured_obs_count"
echo "OBS_BASELINE_GLOBAL_ERROR_HOOKS=$global_error_hook_count"
echo "OBS_BASELINE_RUNTIME_SUMMARY_SCRIPT_MARKERS=$runtime_summary_script_count"

echo "OBS_BASELINE_CRITICAL_SILENT_CATCH_HITS_BEGIN"
rg -n 'catch \(_\)' "${critical_files[@]}" || true
echo "OBS_BASELINE_CRITICAL_SILENT_CATCH_HITS_END"

echo "OBS_BASELINE_STRUCTURED_USAGE_HITS_BEGIN"
rg -n 'AppObservability|ObsCode|_authObsWarn|_chatWarn|_pushWarn|_syncWarn|_dbWarn' \
  "lib/main.dart" \
  "lib/providers/auth_provider.dart" \
  "lib/providers/chat_provider.dart" \
  "lib/services/push_notifications_service.dart" \
  "lib/services/sync_service.dart" \
  "lib/services/db_service.dart" \
  "lib/utils/app_observability.dart" || true
echo "OBS_BASELINE_STRUCTURED_USAGE_HITS_END"
