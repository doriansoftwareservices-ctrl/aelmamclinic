#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: rg is required." >&2
  exit 2
fi

dart_files="$(rg --files lib -g '*.dart' | wc -l | tr -d ' ')"
catch_silent="$( (rg -n 'catch \(_\)' lib || true) | wc -l | tr -d ' ')"
timer_periodic="$( (rg -n 'Timer\.periodic' lib || true) | wc -l | tr -d ' ')"
while_true="$( (rg -n 'while \(true\)' lib || true) | wc -l | tr -d ' ')"

echo "LIB_BASELINE_DART_FILES=$dart_files"
echo "LIB_BASELINE_SILENT_CATCH=$catch_silent"
echo "LIB_BASELINE_TIMER_PERIODIC=$timer_periodic"
echo "LIB_BASELINE_WHILE_TRUE=$while_true"

echo "LIB_BASELINE_TOP_SILENT_CATCH_FILES_BEGIN"
rg -n "catch \(_\)" lib | cut -d: -f1 | sort | uniq -c | sort -nr | sed -n '1,10p' || true
echo "LIB_BASELINE_TOP_SILENT_CATCH_FILES_END"

echo "LIB_BASELINE_TOP_LARGEST_FILES_BEGIN"
find lib -name '*.dart' -print0 | xargs -0 wc -l | sort -nr | sed -n '1,12p' || true
echo "LIB_BASELINE_TOP_LARGEST_FILES_END"
