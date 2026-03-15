#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"

manifest="lib/phase1/critical_path_files.txt"
matrix="lib/phase1/issue_traceability.yaml"

if [[ ! -f "$manifest" || ! -f "$matrix" ]]; then
  echo "ERROR: required files are missing." >&2
  exit 2
fi

missing=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if ! rg -q "^[[:space:]]*- ${file//\//\\/}$" "$matrix"; then
    echo "CRITICAL_MAPPING_MISSING=$file"
    missing=$((missing + 1))
  fi
done < "$manifest"

if [[ "$missing" -gt 0 ]]; then
  echo "CRITICAL_MAPPING_STATUS=fail"
  exit 1
fi

echo "CRITICAL_MAPPING_STATUS=pass"
