#!/usr/bin/env bash
set -euo pipefail

SUB="whfimjipnqbzjlyigbou"
REG="ap-southeast-1"

AUTH="https://${SUB}.auth.${REG}.nhost.run/v1"
GQL="https://${SUB}.hasura.${REG}.nhost.run/v1/graphql"
STO="https://${SUB}.storage.${REG}.nhost.run/v1"
FUN="https://${SUB}.functions.${REG}.nhost.run/v1"

jwt_parts () {
  # يطبع عدد أجزاء JWT (يجب 3)
  awk -F. '{print NF}' <<<"$1"
}

get_token () {
  local label="$1" email pass
  read -r -p "$label email: " email
  read -r -s -p "$label password: " pass; echo >&2

  local hdr body tok parts
  hdr="$(mktemp)"
  body="$(mktemp)"

  curl -sS -D "$hdr" -o "$body" -X POST "${AUTH}/signin/email-password" \
    -H "content-type: application/json" \
    --data-binary "{\"email\":\"${email}\",\"password\":\"${pass}\"}" || true

  # استخراج توكن (stdout فقط = التوكن)
  tok="$(
    python3 - <<PY
import json
raw=open("$body","r",errors="replace").read().strip()
d=json.loads(raw)
s=d.get("session") or {}
t = s.get("accessToken") or s.get("access_token") or d.get("accessToken") or d.get("access_token") or ""
print(t)
PY
  )" || {
    echo "ERROR: non-JSON response for $label" >&2
    echo "---- HEADERS ----" >&2; sed -n '1,40p' "$hdr" >&2 || true
    echo "---- BODY (first 400) ----" >&2; head -c 400 "$body" >&2 || true; echo >&2
    rm -f "$hdr" "$body"
    return 1
  }

  tok="$(printf '%s' "$tok" | tr -d '\r\n')"
  rm -f "$hdr" "$body"

  if [ -z "$tok" ]; then
    echo "ERROR: empty token for $label" >&2
    return 1
  fi

  parts="$(jwt_parts "$tok")"
  echo "$label JWT parts = $parts" >&2
  if [ "$parts" -ne 3 ]; then
    echo "ERROR: $label token is not a valid JWT" >&2
    return 1
  fi

  printf '%s' "$tok"
}

gql () {
  local token="$1"
  local role="$2"
  local payload="$3"

  if [ -n "$role" ]; then
    curl -sS -X POST "$GQL" \
      -H "Authorization: Bearer ${token}" \
      -H "x-hasura-role: ${role}" \
      -H "content-type: application/json" \
      --data-binary "$payload"
  else
    curl -sS -X POST "$GQL" \
      -H "Authorization: Bearer ${token}" \
      -H "content-type: application/json" \
      --data-binary "$payload"
  fi
}

echo "== LOGIN ==" >&2
OWNER_TOKEN="$(get_token OWNER)"
EMPLOYEE_TOKEN="$(get_token EMPLOYEE)"
SUPERADMIN_TOKEN="$(get_token SUPERADMIN)"

echo >&2
echo "== 0) sanity __typename ==" >&2
echo "-- OWNER" >&2;     gql "$OWNER_TOKEN" "" '{"query":"query{__typename}"}'; echo; echo >&2
echo "-- EMPLOYEE" >&2;  gql "$EMPLOYEE_TOKEN" "" '{"query":"query{__typename}"}'; echo; echo >&2
echo "-- SUPERADMIN(user)" >&2;       gql "$SUPERADMIN_TOKEN" "user" '{"query":"query{__typename}"}'; echo; echo >&2
echo "-- SUPERADMIN(superadmin)" >&2; gql "$SUPERADMIN_TOKEN" "superadmin" '{"query":"query{__typename}"}'; echo; echo >&2

echo "== 1) account_feature_permissions SELECT ==" >&2
echo "-- OWNER" >&2;    gql "$OWNER_TOKEN" "" '{"query":"query{account_feature_permissions(limit:1){account_id feature_key allowed}}"}'; echo; echo >&2
echo "-- EMPLOYEE" >&2; gql "$EMPLOYEE_TOKEN" "" '{"query":"query{account_feature_permissions(limit:1){account_id feature_key allowed}}"}'; echo; echo >&2
echo "-- SUPERADMIN(superadmin)" >&2; gql "$SUPERADMIN_TOKEN" "superadmin" '{"query":"query{account_feature_permissions(limit:1){account_id feature_key allowed}}"}'; echo; echo >&2

echo "== 2) account_feature_permissions INSERT (RBAC) ==" >&2
PAYLOAD='{"query":"mutation{insert_account_feature_permissions_one(object:{account_id:\\"00000000-0000-0000-0000-000000000000\\",feature_key:\\"test\\",allowed:true}){account_id}}"}'
echo "-- OWNER insert" >&2;      gql "$OWNER_TOKEN" "" "$PAYLOAD"; echo; echo >&2
echo "-- EMPLOYEE insert" >&2;   gql "$EMPLOYEE_TOKEN" "" "$PAYLOAD"; echo; echo >&2
echo "-- SUPERADMIN insert" >&2; gql "$SUPERADMIN_TOKEN" "superadmin" "$PAYLOAD"; echo; echo >&2

echo "== 3) Storage subscription-proofs create ==" >&2
echo "-- EMPLOYEE should FAIL" >&2
curl -sS --http1.1 -X POST "$STO/files" \
  -H "Authorization: Bearer $EMPLOYEE_TOKEN" \
  -H "content-type: application/json" \
  --data-binary '{"bucketId":"subscription-proofs","name":"emp_proof_test.txt","mimeType":"text/plain"}' ; echo
echo "-- OWNER should PASS" >&2
curl -sS --http1.1 -X POST "$STO/files" \
  -H "Authorization: Bearer $OWNER_TOKEN" \
  -H "content-type: application/json" \
  --data-binary '{"bucketId":"subscription-proofs","name":"owner_proof_test.txt","mimeType":"text/plain"}' ; echo
echo >&2

echo "== 4) Function auth check (SUPERADMIN) ==" >&2
curl -sS -i --http1.1 -X POST "${FUN}/admin-sign-storage-file" \
  -H "Authorization: Bearer $SUPERADMIN_TOKEN" \
  -H "content-type: application/json" \
  --data-binary '{"bucket_id":"chat-attachments","name":"rbac_test.txt","mime_type":"text/plain"}' | head -n 40
echo
