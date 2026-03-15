#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: rg is required." >&2
  exit 2
fi

echo "FUNCTIONS_BASELINE_NODE_CHECK_BEGIN"
while IFS= read -r file; do
  node --check "$file" >/dev/null
done < <(rg --files functions -g '*.js')
echo "FUNCTIONS_BASELINE_NODE_CHECK_END"

jwt_parse_count="$( (rg -n 'parseJwtSub|decodeJwtPayload|token\.split\('\''\.'\''\)' functions -g '*.js' || true) | wc -l | tr -d ' ')"
notify_200_error_count="$( (rg -n 'status\(200\)\.json\(\{ ok: false' functions/notify-*/index.js || true) | wc -l | tr -d ' ')"
notify_secret_check_count="$( (rg -n 'assertWebhookSecret|x-hasura-event-secret|HASURA_EVENT_SECRET|x-webhook-secret' functions/notify-*/index.js || true) | wc -l | tr -d ' ')"
legacy_fcm_count="$( (rg -n 'fcm\.googleapis\.com/fcm/send|Authorization:\s*`key=' functions/_shared/notify_utils.js || true) | wc -l | tr -d ' ')"
upload_size_guard_count="$( (rg -n 'estimateBase64Bytes|MAX_(ATTACHMENT|PROOF)_BYTES' functions/admin-upload-chat-attachment/index.js functions/admin-upload-subscription-proof/index.js || true) | wc -l | tr -d ' ')"
upload_timeout_guard_count="$( (rg -n 'STORAGE_UPLOAD_TIMEOUT_MS|setTimeout\(timeoutMs' functions/admin-upload-chat-attachment/index.js functions/admin-upload-subscription-proof/index.js || true) | wc -l | tr -d ' ')"
duplicate_raw="$(comm -12 <(find functions -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort) <(find functions_disabled -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort) || true)"
archived_duplicates=0
if [[ -f functions_disabled/.archive_manifest.txt ]]; then
  archived_duplicates="$(comm -12 <(printf '%s\n' "$duplicate_raw" | sed '/^$/d' | sort) <(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' functions_disabled/.archive_manifest.txt | sort) | wc -l | tr -d ' ')"
fi
duplicate_disabled_dirs="$(comm -23 <(printf '%s\n' "$duplicate_raw" | sed '/^$/d' | sort) <(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' functions_disabled/.archive_manifest.txt 2>/dev/null | sort) | wc -l | tr -d ' ')"

echo "FUNCTIONS_BASELINE_JWT_PARSE_PATTERNS=$jwt_parse_count"
echo "FUNCTIONS_BASELINE_NOTIFY_200_ON_ERROR=$notify_200_error_count"
echo "FUNCTIONS_BASELINE_NOTIFY_SECRET_CHECK_MATCHES=$notify_secret_check_count"
echo "FUNCTIONS_BASELINE_LEGACY_FCM_PATTERNS=$legacy_fcm_count"
echo "FUNCTIONS_BASELINE_UPLOAD_SIZE_GUARD_MATCHES=$upload_size_guard_count"
echo "FUNCTIONS_BASELINE_UPLOAD_TIMEOUT_GUARD_MATCHES=$upload_timeout_guard_count"
echo "FUNCTIONS_BASELINE_DUPLICATE_DISABLED_DIRS=$duplicate_disabled_dirs"
echo "FUNCTIONS_BASELINE_ARCHIVED_DUPLICATE_DIRS=$archived_duplicates"

echo "FUNCTIONS_BASELINE_CRITICAL_HITS_BEGIN"
rg -n 'parseJwtSub|resolveUserIdFromToken|assertWebhookSecret|estimateBase64Bytes|STORAGE_UPLOAD_TIMEOUT_MS|status\(200\)\.json\(\{ ok: false|fcm\.googleapis\.com/fcm/send|Authorization:\s*`key=' \
  functions/admin-create-superadmin/index.js \
  functions/admin-reset-superadmin-password/index.js \
  functions/admin-upload-chat-attachment/index.js \
  functions/admin-upload-subscription-proof/index.js \
  functions/notify-chat-message/index.js \
  functions/notify-new-patient/index.js \
  functions/notify-plan-request/index.js \
  functions/_shared/notify_utils.js || true
echo "FUNCTIONS_BASELINE_CRITICAL_HITS_END"
