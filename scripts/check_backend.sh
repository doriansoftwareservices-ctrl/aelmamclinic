  #!/usr/bin/env bash
  set -euo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "Project root: ${ROOT_DIR}"
  echo

  CONFIG_JSON="${ROOT_DIR}/config.json"
  if [[ ! -f "${CONFIG_JSON}" ]]; then
    echo "Missing config.json. Expected at: ${CONFIG_JSON}"
    exit 1
  fi

  get_json() {
  python3 - <<PY
  import json
  with open("${CONFIG_JSON}","r",encoding="utf-8") as f:
    data=json.load(f)
  print(data.get("${1}",""))
  PY
  }

  NHOST_GRAPHQL_URL="${NHOST_GRAPHQL_URL:-$(get_json nhostGraphqlUrl)}"
  NHOST_AUTH_URL="${NHOST_AUTH_URL:-$(get_json nhostAuthUrl)}"

  if [[ -z "${NHOST_GRAPHQL_URL}" || -z "${NHOST_AUTH_URL}" ]]; then
    echo "Missing NHOST_GRAPHQL_URL or NHOST_AUTH_URL."
    exit 1
  fi

  CHECKBACKEND_EMAIL="${CHECKBACKEND_EMAIL:-}"
  CHECKBACKEND_PASSWORD="${CHECKBACKEND_PASSWORD:-}"

  if [[ -z "${CHECKBACKEND_EMAIL}" || -z "${CHECKBACKEND_PASSWORD}" ]]; then
    echo "Set CHECKBACKEND_EMAIL and CHECKBACKEND_PASSWORD before running."
    exit 1
  fi

  echo "==[0] Load secrets =="
  echo "GraphQL: ${NHOST_GRAPHQL_URL}"
  echo "Auth:    ${NHOST_AUTH_URL}"
  echo

  echo "==[1] DNS check =="
  for host in \
    "$(echo "${NHOST_GRAPHQL_URL}" | sed -E 's#https?://##' | cut -d/ -f1)" \
    "$(echo "${NHOST_AUTH_URL}" | sed -E 's#https?://##' | cut -d/ -f1)"; do
    if command -v getent >/dev/null 2>&1; then
      echo "- ${host}"
      getent hosts "${host}" || true
    elif command -v nslookup >/dev/null 2>&1; then
      echo "- ${host}"
      nslookup "${host}" || true
    else
      echo "- ${host} (dns tool not found)"
    fi
  done
  echo

  echo "==[2] JWT test (Super Admin) =="
  AUTH_RES="$(curl -s -X POST "${NHOST_AUTH_URL}/signin/email-password" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${CHECKBACKEND_EMAIL}\",\"password\":\"${CHECKBACKEND_PASSWORD}\"}")"

  ACCESS_TOKEN="$(python3 - <<PY
  import json
  try:
    data=json.loads('''${AUTH_RES}''')
    print(data.get("session",{}).get("accessToken",""))
  except Exception:
    print("")
  PY
  )"

  if [[ -z "${ACCESS_TOKEN}" ]]; then
    echo "Auth failed. Response:"
    echo "${AUTH_RES}"
    exit 1
  fi

  export ACCESS_TOKEN

  echo "TOKEN_LEN=${#ACCESS_TOKEN}"
  echo

  echo "==[2.1] JWT payload (decoded) =="
  python3 - <<'PY'
  import base64, os
  payload = os.environ.get("ACCESS_TOKEN","").split(".")[1]
  payload += "=" * (-len(payload) % 4)
  print(base64.urlsafe_b64decode(payload.encode("utf-8")).decode("utf-8"))
  PY
  echo

  echo "==[3] fn_is_super_admin_gql (boolean) with JWT =="
  QUERY='{"query":"query { fn_is_super_admin_gql { is_super_admin } }"}'
  curl -s -X POST "${NHOST_GRAPHQL_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d "${QUERY}"
  echo

  echo "==[DONE] Report ready =="
  '@

  Set-Content -Path .\scripts\check_backend.sh -Value $script -NoNewline