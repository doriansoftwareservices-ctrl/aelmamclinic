#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FILES=(
  "$ROOT/lib/screens/subscription/my_plan_screen.dart"
  "$ROOT/lib/screens/clinic/clinic_profile_screen.dart"
  "$ROOT/lib/screens/reports/report_screen.dart"
  "$ROOT/lib/screens/statistics/statistics_overview_screen.dart"
  "$ROOT/lib/screens/statistics/statistics_screen.dart"
)

join_files() {
  local first=1
  for file in "${FILES[@]}"; do
    if [[ $first -eq 1 ]]; then
      printf '%s' "$file"
      first=0
    else
      printf ' %q' "$file"
    fi
  done
}

FILE_ARGS="$(join_files)"

count_matches() {
  local pattern="$1"
  if rg -n --pcre2 "$pattern" ${FILE_ARGS} >/tmp/phase14_rg.txt 2>/dev/null; then
    wc -l </tmp/phase14_rg.txt
  else
    echo 0
  fi
}

raw_text_hits="$(
  {
    count_matches "(?<!Localized)Text\\(\\s*'[^'\\n]*[اأإء-ي][^'\\n]*'"
    count_matches '(?<!Localized)Text\\(\s*"[^"\n]*[اأإء-ي][^"\n]*"'
  } | awk '{sum += $1} END {print sum + 0}'
)"
fixed_chevron_hits="$(count_matches "const Icon\\(Icons\\.chevron_left_rounded")"
redundant_directionality_hits="$(count_matches "return Directionality\\(")"
export_slug_hits="$(
  {
    count_matches "shareDoc\\(doc, '(income_|doctor_|consumption_|net_)"
    count_matches "downloadDoc\\(context, doc, '(income_|doctor_|consumption_|net_)"
  } | awk '{sum += $1} END {print sum + 0}'
)"

echo "PHASE14_RAW_TEXT_HITS=$raw_text_hits"
echo "PHASE14_FIXED_CHEVRON_HITS=$fixed_chevron_hits"
echo "PHASE14_REDUNDANT_DIRECTIONALITY_HITS=$redundant_directionality_hits"
echo "PHASE14_EXPORT_SLUG_HITS=$export_slug_hits"

if [[ "$raw_text_hits" != "0" ]]; then
  echo "PHASE14_STATUS=FAIL_RAW_TEXT"
  exit 1
fi

if [[ "$fixed_chevron_hits" != "0" ]]; then
  echo "PHASE14_STATUS=FAIL_FIXED_CHEVRON"
  exit 1
fi

if [[ "$redundant_directionality_hits" != "0" ]]; then
  echo "PHASE14_STATUS=FAIL_DIRECTIONALITY"
  exit 1
fi

if [[ "$export_slug_hits" != "0" ]]; then
  echo "PHASE14_STATUS=FAIL_EXPORT_SLUGS"
  exit 1
fi

echo "PHASE14_STATUS=PASS"
