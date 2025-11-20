#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env.wsl ]]; then
  set +u
  # shellcheck disable=SC1091
  source .env.wsl
  set -u
fi
# مرّر بقية الوسائط إلى flutter
exec "$FLUTTER_HOME/bin/flutter" "$@"
