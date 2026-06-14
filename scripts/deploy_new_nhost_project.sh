#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

linked_subdomain="$(
  python3 - <<'PY'
import json
from pathlib import Path

path = Path(".nhost/project.json")
if not path.exists():
    raise SystemExit("")
data = json.loads(path.read_text(encoding="utf-8"))
print(data.get("subdomain", ""))
PY
)"

NHOST_SUBDOMAIN="${NHOST_SUBDOMAIN:-$linked_subdomain}"
NHOST_REGION="${NHOST_REGION:-ap-southeast-1}"
GIT_REF="${GIT_REF:-$(git rev-parse HEAD)}"
DEPLOY_USER="${DEPLOY_USER:-$(git config user.name 2>/dev/null || whoami)}"
DEPLOY_MESSAGE="${DEPLOY_MESSAGE:-$(git log -1 --pretty=%s)}"
NHOST_DEPLOY_TIMEOUT="${NHOST_DEPLOY_TIMEOUT:-15m}"

if [[ -z "$NHOST_SUBDOMAIN" ]]; then
  echo "NHOST_SUBDOMAIN is empty. Run nhost link or set NHOST_SUBDOMAIN." >&2
  exit 1
fi

echo "Repo: $ROOT_DIR"
echo "Subdomain: $NHOST_SUBDOMAIN"
echo "Region: $NHOST_REGION"
echo "Git ref: $GIT_REF"

echo "Validating nhost/nhost.toml syntax..."
python3 - <<'PY'
import tomllib
from pathlib import Path

tomllib.loads(Path("nhost/nhost.toml").read_text(encoding="utf-8"))
print("OK: nhost/nhost.toml is valid TOML")
PY

echo "Checking Nhost config through CLI..."
if [[ "${SKIP_NHOST_VALIDATE:-0}" == "1" ]]; then
  echo "Skipped: SKIP_NHOST_VALIDATE=1"
else
  nhost config validate --subdomain "$NHOST_SUBDOMAIN"
fi

echo "Creating Nhost deployment..."
nhost deployments new "$GIT_REF" \
  --subdomain "$NHOST_SUBDOMAIN" \
  --ref "$GIT_REF" \
  --message "$DEPLOY_MESSAGE" \
  --user "$DEPLOY_USER" \
  --follow \
  --timeout "$NHOST_DEPLOY_TIMEOUT"

echo "Deployment command completed."
