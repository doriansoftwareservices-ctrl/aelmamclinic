#!/usr/bin/env bash
set -euo pipefail

SUB="whfimjipnqbzjlyigbou"
REG="ap-southeast-1"
AUTH="https://${SUB}.auth.${REG}.nhost.run/v1"

get_tok () {
  local label="$1" email pass
  read -r -p "$label email: " email
  read -r -s -p "$label password: " pass; echo >&2

  curl -sS -X POST "${AUTH}/signin/email-password" \
    -H "content-type: application/json" \
    --data-binary "$(printf '{"email":"%s","password":"%s"}' "$email" "$pass")" \
  | python3 -c 'import sys,json
d=json.load(sys.stdin)
s=d.get("session") or {}
tok = s.get("accessToken") or s.get("access_token") or d.get("accessToken") or d.get("access_token") or ""
print(tok)' \
  | tr -d '\r\n'
}

OWNER_TOKEN="$(get_tok OWNER)"
EMPLOYEE_TOKEN="$(get_tok EMPLOYEE)"
SUPERADMIN_TOKEN="$(get_tok SUPERADMIN)"

# اطبع export بصيغة آمنة (بدون ما نحتاج Python)
printf 'export OWNER_TOKEN=%q\n' "$OWNER_TOKEN"
printf 'export EMPLOYEE_TOKEN=%q\n' "$EMPLOYEE_TOKEN"
printf 'export SUPERADMIN_TOKEN=%q\n' "$SUPERADMIN_TOKEN"
