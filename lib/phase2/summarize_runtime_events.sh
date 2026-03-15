#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

LOG_FILE="${1:-}"
if [[ -z "$LOG_FILE" ]]; then
  candidates=()
  if [[ -n "${LOCALAPPDATA:-}" ]]; then
    candidates+=("${LOCALAPPDATA}/ElmamClinic/logs/app_runtime_events.jsonl")
  fi
  if [[ -n "${USERPROFILE:-}" ]]; then
    candidates+=("${USERPROFILE}/AppData/Local/ElmamClinic/logs/app_runtime_events.jsonl")
  fi
  candidates+=("/tmp/ElmamClinic/logs/app_runtime_events.jsonl")
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      LOG_FILE="$candidate"
      break
    fi
  done
fi

if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
  echo "OBS_RUNTIME_SUMMARY_STATUS=NO_LOG_FILE"
  echo "OBS_RUNTIME_SUMMARY_MESSAGE=app_runtime_events.jsonl not found"
  exit 0
fi

python3 - "$LOG_FILE" <<'PY'
import json
import sys
from collections import Counter

path = sys.argv[1]
codes = Counter()
scopes = Counter()
levels = Counter()
total = 0

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except Exception:
            continue
        total += 1
        code = str(payload.get("code") or "").strip()
        scope = str(payload.get("scope") or "").strip()
        level = str(payload.get("level") or "").strip()
        if code:
            codes[code] += 1
        if scope:
            scopes[scope] += 1
        if level:
            levels[level] += 1

print(f"OBS_RUNTIME_SUMMARY_STATUS=OK")
print(f"OBS_RUNTIME_SUMMARY_FILE={path}")
print(f"OBS_RUNTIME_SUMMARY_TOTAL={total}")
print("OBS_RUNTIME_SUMMARY_TOP_CODES_BEGIN")
for code, count in codes.most_common(10):
    print(f"{count:6d} {code}")
print("OBS_RUNTIME_SUMMARY_TOP_CODES_END")
print("OBS_RUNTIME_SUMMARY_TOP_SCOPES_BEGIN")
for scope, count in scopes.most_common(10):
    print(f"{count:6d} {scope}")
print("OBS_RUNTIME_SUMMARY_TOP_SCOPES_END")
print("OBS_RUNTIME_SUMMARY_LEVELS_BEGIN")
for level, count in levels.most_common():
    print(f"{count:6d} {level}")
print("OBS_RUNTIME_SUMMARY_LEVELS_END")
PY
