#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

AUTH_FILE="$ROOT_DIR/lib/providers/auth_provider.dart"
MAIN_FILE="$ROOT_DIR/lib/main.dart"
LOGIN_FILE="$ROOT_DIR/lib/screens/auth/login_screen.dart"
GUARD_FILE="$ROOT_DIR/lib/widgets/auth_guard_listener.dart"

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

require_literal "auth topology getter hasLocalSession" "bool get hasLocalSession" "$AUTH_FILE"
require_literal "auth topology getter needsRemoteSessionRecovery" "bool get needsRemoteSessionRecovery" "$AUTH_FILE"
require_literal "auth topology getter needsAccountContextResolution" "bool get needsAccountContextResolution" "$AUTH_FILE"
require_literal "auth topology getter canEnterClinicShell" "bool get canEnterClinicShell" "$AUTH_FILE"
require_literal "auth topology getter canEnterRemoteAdminShell" "bool get canEnterRemoteAdminShell" "$AUTH_FILE"
require_literal "auth topology getter hasReadyAppShell" "bool get hasReadyAppShell" "$AUTH_FILE"
require_literal "auth topology getter canRunRemoteBoundServices" "bool get canRunRemoteBoundServices" "$AUTH_FILE"
require_literal "auth reconciliation API" "Future<AuthSessionResult> reconcileAuthenticatedSession" "$AUTH_FILE"
require_literal "auth topology state label" "String get sessionTopologyState" "$AUTH_FILE"

require_absent "main no longer contains session restore blocker" "_SessionRestoreScreen" "$MAIN_FILE"
require_absent "main no longer contains post login bootstrap blocker" "_PostLoginBootstrapScreen" "$MAIN_FILE"
require_literal "main gates remote-bound services" "final remoteBoundReady = auth.canRunRemoteBoundServices;" "$MAIN_FILE"
require_literal "main routes super admin via canEnterRemoteAdminShell" "auth.canEnterRemoteAdminShell" "$MAIN_FILE"
require_literal "main routes clinic shell via canEnterClinicShell" "auth.canEnterClinicShell" "$MAIN_FILE"

require_literal "auth guard uses reconciliation flow" "auth.reconcileAuthenticatedSession(" "$GUARD_FILE"
require_literal "login screen recovery gate" "_shouldShowAuthenticatedRecovery" "$LOGIN_FILE"
require_literal "login screen recovery retry" "_retryAuthenticatedRecovery" "$LOGIN_FILE"
require_literal "login screen account completion retry" "_completeAuthenticatedAccountSetup" "$LOGIN_FILE"

python3 - "$LOGIN_FILE" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
bad = re.search(r"AuthSessionStatus\.noAccount(?:(?!AuthSessionStatus\.).){0,320}?signOut\(", text, re.S)
if bad:
    print("FAIL: login screen still forces signOut inside noAccount branches", file=sys.stderr)
    sys.exit(1)
print("PASS: login screen preserves session inside noAccount branches")
PY

auth_topology_getters="$( (rg -n "bool get (hasLocalSession|needsRemoteSessionRecovery|needsAccountContextResolution|canEnterClinicShell|canEnterRemoteAdminShell|hasReadyAppShell|canRunRemoteBoundServices)" "$AUTH_FILE" || true) | wc -l | tr -d ' ' )"
reconcile_hooks="$( (rg -n "reconcileAuthenticatedSession" "$AUTH_FILE" "$LOGIN_FILE" "$GUARD_FILE" || true) | wc -l | tr -d ' ' )"
blocking_symbols="$( (rg -n "_SessionRestoreScreen|_PostLoginBootstrapScreen" "$MAIN_FILE" || true) | wc -l | tr -d ' ' )"

echo "METRIC auth_topology_getters=$auth_topology_getters"
echo "METRIC reconcile_hooks=$reconcile_hooks"
echo "METRIC blocking_symbols=$blocking_symbols"
