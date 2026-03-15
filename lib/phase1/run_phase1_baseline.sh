#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

REPORT_FILE="lib/phase1/phase1_baseline_latest.txt"
DATE_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TOOL_HOME="$ROOT_DIR/.tooling/phase1_home"
mkdir -p "$TOOL_HOME"

FLUTTER_BIN="flutter"
DART_BIN="dart"
if [[ -x "$ROOT_DIR/tools/flutter-sdk-linux/bin/flutter" ]]; then
  FLUTTER_BIN="$ROOT_DIR/tools/flutter-sdk-linux/bin/flutter"
fi
if [[ -x "$ROOT_DIR/tools/flutter-sdk-linux/bin/dart" ]]; then
  DART_BIN="$ROOT_DIR/tools/flutter-sdk-linux/bin/dart"
fi

{
  echo "PHASE1_BASELINE_REPORT"
  echo "generated_at_utc=$DATE_UTC"
  echo "repo_root=$ROOT_DIR"
  echo "tool_home=$TOOL_HOME"
  echo "flutter_bin=$FLUTTER_BIN"
  echo "dart_bin=$DART_BIN"
  echo
  echo "=== LIB CHECK ==="
  bash lib/phase1/check_lib_baseline.sh
  echo
  echo "=== FUNCTIONS CHECK ==="
  bash functions/phase1/check_functions_baseline.sh
  echo
  echo "=== NHOST CHECK ==="
  bash nhost/phase1/check_nhost_baseline.sh
  echo
  echo "=== TRACEABILITY CHECK ==="
  bash lib/phase1/validate_critical_mapping.sh
  echo
  echo "=== TOOLCHAIN CHECK ==="
  toolchain_ok=1
  if HOME="$TOOL_HOME" "$DART_BIN" --version >/tmp/phase1_dart_version.out 2>/tmp/phase1_dart_version.err; then
    echo "DART_STATUS=ok"
    cat /tmp/phase1_dart_version.out
  else
    toolchain_ok=0
    echo "DART_STATUS=blocked"
    cat /tmp/phase1_dart_version.err
  fi
  if HOME="$TOOL_HOME" "$FLUTTER_BIN" --version >/tmp/phase1_flutter_version.out 2>/tmp/phase1_flutter_version.err; then
    echo "FLUTTER_STATUS=ok"
    cat /tmp/phase1_flutter_version.out
  else
    toolchain_ok=0
    echo "FLUTTER_STATUS=blocked"
    cat /tmp/phase1_flutter_version.err
  fi
  if [[ "$toolchain_ok" -eq 1 ]]; then
    HOME="$TOOL_HOME" "$FLUTTER_BIN" --disable-analytics >/tmp/phase1_flutter_analytics.out 2>/tmp/phase1_flutter_analytics.err || true
    echo "ANALYZE_STATUS=running"
    if HOME="$TOOL_HOME" "$FLUTTER_BIN" analyze >/tmp/phase1_flutter_analyze.out 2>/tmp/phase1_flutter_analyze.err; then
      echo "ANALYZE_RESULT=pass"
    else
      echo "ANALYZE_RESULT=fail"
      cat /tmp/phase1_flutter_analyze.err
    fi
    echo "TEST_STATUS=running"
    if HOME="$TOOL_HOME" "$FLUTTER_BIN" test >/tmp/phase1_flutter_test.out 2>/tmp/phase1_flutter_test.err; then
      echo "TEST_RESULT=pass"
    else
      echo "TEST_RESULT=fail"
      cat /tmp/phase1_flutter_test.err
    fi
  else
    echo "ANALYZE_STATUS=blocked_by_toolchain"
    echo "TEST_STATUS=blocked_by_toolchain"
  fi
} >"$REPORT_FILE"

echo "Phase 1 baseline report written to: $REPORT_FILE"
