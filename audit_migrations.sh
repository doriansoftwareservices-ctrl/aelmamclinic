#!/usr/bin/env bash
set -euo pipefail

ROOT="nhost/migrations/default"

echo "==[A] auth.uid/auth.jwt (Supabase-specific) =="
grep -RIn --include="*.sql" -E '\bauth\.(uid|jwt)\s*\(' "$ROOT" || true
echo

echo "==[B] request_uid_text usage (likely uuid=text) =="
grep -RIn --include="*.sql" -E 'request_uid_text\(\)' "$ROOT" || true
echo

echo "==[C] Comparisons to request_uid_text WITHOUT cast =="
grep -RIn --include="*.sql" -E '=\s*public\.request_uid_text\(\)\b(?!\s*::uuid)' "$ROOT" || true
echo

echo "==[D] TO/GRANT authenticated/service_role (role missing in Nhost) =="
grep -RIn --include="*.sql" -E '\bTO\s+(authenticated|service_role)\b' "$ROOT" || true
grep -RIn --include="*.sql" -E '\bgrant\s+execute\b.*\bto\s+(authenticated|service_role)\b' "$ROOT" || true
echo

echo "==[E] storage differences (Nhost != Supabase) =="
grep -RIn --include="*.sql" -E '\bstorage\.(objects|create_bucket)\b' "$ROOT" || true
grep -RIn --include="*.sql" -E '\bstorage\.buckets\b.*\bpublic\b' "$ROOT" || true
echo

echo "==[F] supabase_realtime publication =="
grep -RIn --include="*.sql" -E '\bpublication\b.*supabase_realtime|alter\s+publication\s+supabase_realtime' "$ROOT" || true
echo

echo "==[G] set local role supabase_storage_admin (may fail) =="
grep -RIn --include="*.sql" -E 'set\s+local\s+role\s+supabase_storage_admin' "$ROOT" || true
echo

echo "==[H] Empty SQL files (will cause EmptyQuery) =="
python3 - <<'PY'
import pathlib, re
root = pathlib.Path("nhost/migrations/default")
bad=[]
for p in root.rglob("*.sql"):
    txt = p.read_text(encoding="utf-8", errors="ignore").lstrip("\ufeff")
    txt = re.sub(r'^\s*--.*$', '', txt, flags=re.M)
    if re.sub(r'[\s;]+', '', txt) == '':
        bad.append(str(p))
for p in bad:
    print(p)
print(f"empty_sql_files={len(bad)}")
PY
