# Nhost Migration Plan (Supabase → Nhost)

This plan migrates the schema + data into Nhost with minimal downtime and
verifiable checks. All exports stay local; nothing is stored back on Supabase.

## 0) Freeze Writes
- Put the app in maintenance mode (block logins or disable writes).
- Stop any background sync from clients.

## 1) Export Data Locally from Supabase
Use your old database connection string (from Supabase dashboard).
Export only the `public` schema data (auth/storage handled separately).

Example:
```
pg_dump \
  --data-only \
  --column-inserts \
  --disable-triggers \
  --schema=public \
  "$SUPABASE_DB_URL" > /tmp/supabase_public_data.sql
```

Optional: export schema for reference (not required if Nhost migrations are applied):
```
pg_dump --schema-only --schema=public "$SUPABASE_DB_URL" > /tmp/supabase_public_schema.sql
```

## 2) Ensure Nhost Schema + Metadata Are Applied
Deploy migrations + metadata:
```
nhost deployments new --ref HEAD --message "Apply migrations/metadata" --user "zidan" --follow
```

## 3) Import Public Data into Nhost
Use the Nhost database URL (from Nhost dashboard).
```
psql "$NHOST_DB_URL" -f /tmp/supabase_public_data.sql
```

## 4) Migrate Auth Users (Recommended Safe Path)
Passwords are NOT portable between providers. The safe path is to import users
by email and trigger a password reset flow:
1) Export users from Supabase:
```
psql "$SUPABASE_DB_URL" -c "COPY (SELECT id, email FROM auth.users) TO STDOUT WITH CSV HEADER" > /tmp/auth_users.csv
```
2) Import users to Nhost via Admin API or a one-time script and send reset emails.

If you need a custom admin-import script, tell me and I will generate it.

## 5) Migrate Storage (Chat Attachments)
Supabase storage files must be downloaded and re-uploaded to Nhost storage.
- Keep the same bucket name: `chat-attachments`
- Keep the same logical path format: `attachments/<conversationId>/<messageId>/<fileName>`

If you want an automated transfer script, tell me which CLI/tools you prefer.

## 6) Post-Migration Checks (Required)
Run the SQL checks in:
```
scripts/nhost_post_migration_checks.sql
```

## 7) Re-enable Clients
After checks pass:
- Deploy the latest app build (pointed to Nhost).
- Re-enable writes and sync.

## 8) Cleanup
Remove any remaining Supabase credentials from machines/CI.
Keep only local export files if you want a rollback option.
