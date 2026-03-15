#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

STORE_FILE="$ROOT_DIR/lib/core/active_account_store.dart"
AUTH_FILE="$ROOT_DIR/lib/providers/auth_provider.dart"
DB_FILE="$ROOT_DIR/lib/services/db_service.dart"
LOGIN_FILE="$ROOT_DIR/lib/screens/auth/login_screen.dart"
GUARD_FILE="$ROOT_DIR/lib/widgets/auth_guard_listener.dart"
AUTH_TEST="$ROOT_DIR/test/providers/auth_provider_isolation_test.dart"
DB_TEST="$ROOT_DIR/test/services/db_service_account_isolation_test.dart"

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_literal() {
  local label="$1"
  local literal="$2"
  local file="$3"
  if rg -Fq "$literal" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

require_absent() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if rg -n "$pattern" "$file" >/dev/null 2>&1; then
    fail "$label"
  else
    pass "$label"
  fi
}

require_literal "active account store supports pending wipe gating" \
  "Future<String?> readAccountId({bool allowPendingWipe = false})" "$STORE_FILE"
require_literal "active account store exposes test reset" \
  "static void resetForTesting()" "$STORE_FILE"

require_literal "auth provider exposes isolation gate" \
  "bool get requiresLocalIsolationWipe" "$AUTH_FILE"
require_literal "auth provider applies pending wipe state" \
  "Future<void> _applyPendingLocalWipeState" "$AUTH_FILE"
require_literal "auth provider executes pending wipe" \
  "Future<bool> performPendingLocalWipe" "$AUTH_FILE"
require_literal "auth provider debug remote session override" \
  "void debugSetHasNhostSession" "$AUTH_FILE"

require_literal "db service guards on pending isolation" \
  "Future<bool> _isAccountIsolationPending()" "$DB_FILE"
require_literal "db service blocks account filter during pending isolation" \
  "return ' AND 1=0';" "$DB_FILE"
require_literal "db service exposes debug account filter helper" \
  "Future<String> debugAccountFilterClause" "$DB_FILE"

require_literal "login screen resolves pending local wipe" \
  "_resolvePendingLocalWipe" "$LOGIN_FILE"
require_literal "login recovery shows isolation title" \
  "auth_recovery_isolation_title" "$LOGIN_FILE"
require_literal "login recovery uses wipe action label" \
  "auth_action_backup_and_wipe_now" "$LOGIN_FILE"

require_literal "auth guard uses strict pending wipe message" \
  "auth_pending_wipe_guard_message" "$GUARD_FILE"
require_literal "auth guard exposes wipe action" \
  "auth_action_backup_and_wipe_now" "$GUARD_FILE"
require_literal "auth guard exposes logout action" \
  "common_logout" "$GUARD_FILE"
require_absent "auth guard no longer offers defer option" "لاحقًا" "$GUARD_FILE"
require_absent "auth guard no longer offers cancel option" "common_cancel" "$GUARD_FILE"

require_literal "auth isolation unit test exists" \
  "pending local wipe forces isolation topology for clinic users" "$AUTH_TEST"
require_literal "db isolation unit test exists" \
  "pending isolation hides current account resolution and blocks account filters" "$DB_TEST"

isolation_symbols="$( (rg -n "pendingLocalWipe|requiresLocalIsolationWipe|_resolvePendingLocalWipe|debugAccountFilterClause|_isAccountIsolationPending" \
  "$STORE_FILE" "$AUTH_FILE" "$DB_FILE" "$LOGIN_FILE" "$GUARD_FILE" || true) | wc -l | tr -d ' ' )"
strict_wipe_actions="$( (rg -n "auth_action_backup_and_wipe_now|performPendingLocalWipe|auth_pending_wipe_guard_message" \
  "$LOGIN_FILE" "$GUARD_FILE" "$AUTH_FILE" || true) | wc -l | tr -d ' ' )"
phase4_tests="$( (rg -n "test\\('" "$AUTH_TEST" "$DB_TEST" || true) | wc -l | tr -d ' ' )"

echo "METRIC isolation_symbols=$isolation_symbols"
echo "METRIC strict_wipe_actions=$strict_wipe_actions"
echo "METRIC phase4_tests=$phase4_tests"
