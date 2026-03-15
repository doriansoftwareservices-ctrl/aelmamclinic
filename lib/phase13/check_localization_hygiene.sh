#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI_ALLOWLIST="$ROOT/lib/phase13/localization_ui_allowlist.txt"
DIRECTION_ALLOWLIST="$ROOT/lib/phase13/localization_direction_allowlist.txt"

if [[ ! -f "$UI_ALLOWLIST" ]]; then
  echo "missing allowlist: $UI_ALLOWLIST" >&2
  exit 1
fi

if [[ ! -f "$DIRECTION_ALLOWLIST" ]]; then
  echo "missing allowlist: $DIRECTION_ALLOWLIST" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

UI_HITS="$TMP_DIR/ui_hits.txt"
DIRECTION_HITS="$TMP_DIR/direction_hits.txt"
UNEXPECTED_UI="$TMP_DIR/unexpected_ui.txt"
UNEXPECTED_DIRECTION="$TMP_DIR/unexpected_direction.txt"

rg -n \
  --glob 'lib/screens/**' \
  --glob 'lib/widgets/**' \
  --glob 'lib/services/**' \
  --glob 'lib/core/**' \
  --glob 'lib/utils/**' \
  "Text\\('.*[ء-ي]|label:\\s*'.*[ء-ي]|title:\\s*'.*[ء-ي]|subtitle:\\s*'.*[ء-ي]|hintText:\\s*'.*[ء-ي]|tooltip:\\s*'.*[ء-ي]|helperText:\\s*'.*[ء-ي]|return\\s*'.*[ء-ي]|'[^'\\n]*[ء-ي][^'\\n]*\\.(xlsx|csv|pdf|html)|\\\"[^\\\"\\n]*[ء-ي][^\\\"\\n]*\\.(xlsx|csv|pdf|html)" \
  "$ROOT/lib/screens" \
  "$ROOT/lib/widgets" \
  "$ROOT/lib/services" \
  "$ROOT/lib/core" \
  "$ROOT/lib/utils" >"$UI_HITS" || true

rg -n \
  --glob 'lib/screens/**' \
  --glob 'lib/widgets/**' \
  --glob 'lib/services/**' \
  --glob 'lib/core/**' \
  --glob 'lib/utils/**' \
  "textDirection:\\s*(TextDirection|ui\\.TextDirection)\\.(ltr|rtl)|return Directionality\\(|=> Directionality\\(" \
  "$ROOT/lib/screens" \
  "$ROOT/lib/widgets" \
  "$ROOT/lib/services" \
  "$ROOT/lib/core" \
  "$ROOT/lib/utils" >"$DIRECTION_HITS" || true

filter_unexpected() {
  local hits_file="$1"
  local allowlist_file="$2"
  local output_file="$3"
  : >"$output_file"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local file="${line%%:*}"
    if ! grep -Fqx "$file" "$allowlist_file"; then
      printf '%s\n' "$line" >>"$output_file"
    fi
  done <"$hits_file"
}

filter_unexpected "$UI_HITS" "$UI_ALLOWLIST" "$UNEXPECTED_UI"
filter_unexpected "$DIRECTION_HITS" "$DIRECTION_ALLOWLIST" "$UNEXPECTED_DIRECTION"

ui_total="$(wc -l <"$UI_HITS" | tr -d ' ')"
ui_files="$(cut -d: -f1 "$UI_HITS" | sort -u | wc -l | tr -d ' ')"
direction_total="$(wc -l <"$DIRECTION_HITS" | tr -d ' ')"
direction_files="$(cut -d: -f1 "$DIRECTION_HITS" | sort -u | wc -l | tr -d ' ')"
unexpected_ui_total="$(wc -l <"$UNEXPECTED_UI" | tr -d ' ')"
unexpected_direction_total="$(wc -l <"$UNEXPECTED_DIRECTION" | tr -d ' ')"

echo "LOCALIZATION_UI_HITS=$ui_total"
echo "LOCALIZATION_UI_FILES=$ui_files"
echo "LOCALIZATION_DIRECTION_HITS=$direction_total"
echo "LOCALIZATION_DIRECTION_FILES=$direction_files"
echo "LOCALIZATION_UNEXPECTED_UI_HITS=$unexpected_ui_total"
echo "LOCALIZATION_UNEXPECTED_DIRECTION_HITS=$unexpected_direction_total"

if [[ "$unexpected_ui_total" -gt 0 ]]; then
  echo
  echo "Unexpected raw-Arabic UI hits outside the current phase baseline:"
  cat "$UNEXPECTED_UI"
fi

if [[ "$unexpected_direction_total" -gt 0 ]]; then
  echo
  echo "Unexpected hard-coded directionality hits outside the current phase baseline:"
  cat "$UNEXPECTED_DIRECTION"
fi

if [[ "$unexpected_ui_total" -gt 0 || "$unexpected_direction_total" -gt 0 ]]; then
  exit 1
fi

echo "LOCALIZATION_HYGIENE_STATUS=PASS"
