#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

SYNC_FILE="$ROOT_DIR/lib/services/sync_service.dart"
AUTH_FILE="$ROOT_DIR/lib/services/nhost_auth_service.dart"
HELPER_FILE="$ROOT_DIR/lib/phase5/sync_determinism.dart"
TEST_FILE="$ROOT_DIR/test/services/sync_determinism_test.dart"
OBS_FILE="$ROOT_DIR/lib/utils/app_observability.dart"

rg -n "enum SyncLifecyclePhase|class SyncRetryPolicy|computeSyncPullSchedule" \
  "$HELPER_FILE" >/dev/null

rg -n "List<Completer<void>> _idleWaiters|_scheduleNextPullCheck|_schedulePullRetry|_requestPullIfNeeded|pullAll\\(" \
  "$SYNC_FILE" >/dev/null

rg -n "bootstrap_dirty_flush" "$AUTH_FILE" >/dev/null

rg -n "syncStateTransition|syncPullScheduled|syncPullSkipped|syncPullFailed|syncRetryScheduled|syncWaitForIdleTimeout" \
  "$OBS_FILE" >/dev/null

rg -n "test\\('" "$TEST_FILE" >/dev/null

if rg -n "Timer\\.periodic" "$SYNC_FILE" >/dev/null; then
  echo "sync_service still contains Timer.periodic" >&2
  exit 1
fi

if rg -n "while \\(_pushBusy" "$SYNC_FILE" >/dev/null; then
  echo "sync_service still contains busy-wait push locking" >&2
  exit 1
fi

if rg -n "Future<void>\\.delayed\\(const Duration\\(milliseconds: 80\\)\\)" "$SYNC_FILE" >/dev/null; then
  echo "sync_service still contains legacy waitForIdle polling" >&2
  exit 1
fi

echo "Phase 5 sync determinism baseline passed."
