#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

PROVIDER_FILE="$ROOT_DIR/lib/providers/chat_provider.dart"
REALTIME_FILE="$ROOT_DIR/lib/services/chat_realtime_notifier.dart"
LOCAL_FILE="$ROOT_DIR/lib/local/chat_local_store.dart"
HELPER_FILE="$ROOT_DIR/lib/phase6/chat_reliability.dart"
OBS_FILE="$ROOT_DIR/lib/utils/app_observability.dart"
TEST_FILE="$ROOT_DIR/test/services/chat_reliability_test.dart"

rg -n "bool hasBoundChatAccount|String buildChatStorageScopeKey|class ChatRetryPolicy" \
  "$HELPER_FILE" >/dev/null

rg -n "ensureSessionScope|buildChatStorageScopeKey|_requestOutboxFlush|_flushOutboxItem|accountId: _accountFilter" \
  "$PROVIDER_FILE" >/dev/null

rg -n 'chat realtime start blocked because account scope is missing|query MyConversationIds|subscription MyParticipants|subscription LatestMessages|account_id: \{_eq: \$accountId\}' \
  "$REALTIME_FILE" >/dev/null

rg -n "_tableSessionMeta|ensureSessionScope|account_id TEXT" \
  "$LOCAL_FILE" >/dev/null

rg -n "chatAccountScopeRequired|chatLocalScopeReset|chatRealtimeRestartFailed|chatRealtimeSubscriptionFailed|chatOutboxFlushFailed" \
  "$OBS_FILE" >/dev/null

rg -n "test\\('" "$TEST_FILE" >/dev/null

if rg -n "while \\(true\\)" "$PROVIDER_FILE" >/dev/null; then
  echo "chat_provider still contains while(true)" >&2
  exit 1
fi

if rg -n "Timer\\.periodic" "$PROVIDER_FILE" >/dev/null; then
  echo "chat_provider still contains Timer.periodic" >&2
  exit 1
fi

if rg -n "limit: 500" "$REALTIME_FILE" >/dev/null; then
  echo "chat realtime notifier still uses legacy 500-message subscription window" >&2
  exit 1
fi

if rg -n "super_admin_missing_account_filter|using global view" "$PROVIDER_FILE" >/dev/null; then
  echo "chat provider still contains unrestricted global fallback" >&2
  exit 1
fi

if rg -n "_local\\.getOutbox\\(\\)" "$PROVIDER_FILE" >/dev/null; then
  echo "chat provider still reads outbox without account scope" >&2
  exit 1
fi

echo "Phase 6 chat isolation baseline passed."
