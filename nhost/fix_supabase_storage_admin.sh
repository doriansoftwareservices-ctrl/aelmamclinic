#!/usr/bin/env bash
set -euo pipefail

ROOT="nhost/migrations/default"

python3 - <<'PY'
from pathlib import Path
import re

root = Path("nhost/migrations/default")
files = list(root.rglob("*.sql"))
patched = 0

for p in files:
    txt = p.read_text(encoding="utf-8", errors="ignore")
    if "set local role supabase_storage_admin" not in txt:
        continue

    # إذا كان الملف فيه متغير lacking := false نستعمله
    has_lacking = re.search(r"\blacking\s+boolean\b", txt, re.I) is not None

    # إذا كان تم عمل patch سابقًا (WHEN others) لا نكرر
    if re.search(r"set local role supabase_storage_admin.*?WHEN\s+others", txt, re.I | re.S):
        continue

    if has_lacking:
        repl = (
            "BEGIN\n"
            "    EXECUTE 'set local role supabase_storage_admin';\n"
            "  EXCEPTION WHEN others THEN\n"
            "    lacking := true;\n"
            "  END;"
        )
    else:
        repl = (
            "BEGIN\n"
            "    EXECUTE 'set local role supabase_storage_admin';\n"
            "  EXCEPTION WHEN others THEN\n"
            "    RETURN;\n"
            "  END;"
        )

    new_txt, n = re.subn(
        r"EXECUTE\s*'set\s+local\s+role\s+supabase_storage_admin'\s*;",
        repl,
        txt,
        flags=re.I
    )

    if n:
        p.write_text(new_txt, encoding="utf-8")
        patched += 1

print(f"patched_files={patched}")
PY

echo "Done."
