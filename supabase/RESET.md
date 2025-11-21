# Supabase Factory Reset & Redeploy

Use these steps when you need to wipe the hosted project and rebuild it from the migrations/functions that live in this repository.

> **Warning:** A remote reset permanently deletes every row, storage object, and authentication record. Always take a backup first and double‑check that you are targeting the correct project reference.

## 0. Prerequisites

- Supabase CLI ≥ v1.174 (`supabase --version`).
- A `SUPABASE_ACCESS_TOKEN` with owner rights (`supabase login`).
- The project reference, e.g. `kdcgpgcyxpameowcopqb`.
- The database password (visible in the Supabase dashboard).
- This workspace’s `.env` (or CLI flags) containing the runtime values you want to deploy, e.g. `SUPABASE_URL`, `SUPABASE_DB_PASSWORD`, storage S3 creds if any, etc.

```bash
# recommended local env file
cat <<'EOF' > supabase/.env.production
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_DB_PASSWORD=...
EOF
```

## 1. Take a backup (cannot be skipped)

```bash
cd C:\Users\zidan\AndroidStudioProjects\aelmamclinic
supabase db remote commit \
  --project-ref <project-ref> \
  --db-url "postgresql://postgres:<DB_PASSWORD>@db.<project-ref>.supabase.co:5432/postgres" \
  --output supabase/backups/remote_$(Get-Date -Format yyyyMMdd_HHmmss).sql
```

Optional but recommended:

- Export Storage buckets (Settings → Storage → “Export” or via `supabase storage list buckets && supabase storage download ...`).
- Download Edge Function logs if you need them for auditing.

## 2. Factory reset the remote project

```bash
supabase db remote reset \
  --project-ref <project-ref> \
  --password "<DB_PASSWORD>"
```

The CLI prompts for confirmation; type `y`. This recreates a clean database that only has `supabase/migrations/*.sql` applied when you push again.

## 3. Deploy schema & functions from this repo

```bash
supabase db push \
  --project-ref <project-ref> \
  --env-file supabase/.env.production
```

This replays every migration (including `20251031090000_harden_admin_rpcs.sql`) so the server exactly matches the codebase, with hardened grants and the latest chat/storage tables.

Then deploy each function:

```bash
for %%f in (supabase\functions\*) do (
  supabase functions deploy "%%~nxf" --project-ref <project-ref> --no-verify-jwt
)
```

or deploy individually, e.g.

```bash
supabase functions deploy admin__create_employee --project-ref <project-ref>
```

## 4. Upload storage policies / configuration

All storage policies and buckets are defined in the migrations, so no manual SQL is required. If you exported bucket objects earlier, re-upload them via:

```bash
supabase storage cp .\backups\chat-attachments\* chat-attachments/ --project-ref <project-ref>
```

## 5. Smoke-test the deployment

1. Run `supabase db remote commit --project-ref <project-ref> --output supabase_build_after_reset.sql` and verify it diff-matches the repo.
2. Test critical RPCs (e.g. `admin_bootstrap_clinic_for_email`) via the SQL editor to confirm grants are correct.
3. From Flutter, ensure `AppConstants.loadRuntimeOverrides` finds the correct `config.json` or pass `--dart-define SUPABASE_URL=...`.

Once these checks pass, the project is considered “reset” and aligned with the files in `supabase/`.
