#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[1/4] Checking changed function syntax"
node --check functions/_shared/storage_utils.js
node --check functions/admin-create-superadmin/index.js
node --check functions/admin-reset-superadmin-password/index.js

echo "[2/4] Checking root email references"
grep -R "elmam.clinic.c.s@elmam.com" -n \
  functions/admin-create-superadmin/index.js \
  functions/admin-reset-superadmin-password/index.js \
  lib/core/nhost_config.dart \
  nhost/migrations/default/20260615003000_harden_root_superadmin_runtime/up.sql && {
    echo "[FAILED] legacy root email still exists in active patched files"
    exit 1
  } || true

echo "[3/4] Checking support_ratings tab parity"
grep -R "support_ratings" -n \
  functions/admin-create-superadmin/index.js \
  nhost/migrations/default/20260615003000_harden_root_superadmin_runtime/up.sql >/dev/null

echo "[4/4] Patch static checks passed"
