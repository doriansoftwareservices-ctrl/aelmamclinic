Phase 1 Baseline (Snapshot + Risk Register)

Timestamp: 2025-12-24 17:19:51

Snapshot Artifacts
- backups/phase1_20251224_171951/nhost_migrations.tar
- backups/phase1_20251224_171951/nhost_metadata.tar
- backups/phase1_20251224_171951/nhost_functions.tar
- backups/phase1_20251224_171951/nhost_config.tar
- backups/phase1_20251224_171951/app_core.tar
- backups/phase1_20251224_171951/project_config.tar
- backups/phase1_20251224_171951/project_metadata.tar
- backups/phase1_20251224_171951/nhost_migrations (partial copy from timed out operation)

Baseline Checks (Evidence)
- Migrations count: 118
- Empty SQL files (5):
  - nhost/migrations/default/20251220130000_fix_jwt_claims_json_cast/down.sql
  - nhost/migrations/default/20251220133000_update_fn_is_super_admin_gql_claims/down.sql
  - nhost/migrations/default/20251220140000_fn_is_super_admin_gql_claims_fallback/down.sql
  - nhost/migrations/default/20251220150000_fn_is_super_admin_gql_session_uid/down.sql
  - nhost/migrations/default/20251220153000_fn_is_super_admin_gql_invoker/down.sql
- Placeholder migrations (5):
  - nhost/migrations/default/20250904_placeholder
  - nhost/migrations/default/20250913000000_placeholder
  - nhost/migrations/default/20250913000500_placeholder
  - nhost/migrations/default/20250913001000_placeholder
  - nhost/migrations/default/20251030000000_placeholder
- Metadata coverage: no tracked table entries found for core domain tables in
  nhost/metadata/databases/default/tables/tables.yaml (patients/items/etc.).

Security Notes (No values recorded)
- config.json exists and contains Nhost admin/webhook/jwt secrets. These must
  not be committed and will be rotated in Phase 2.

Risk Register (for upcoming phases)
- Secrets exposed to client runtime (config.json + runtime overrides).
- Missing Hasura metadata tracking for core tables blocks GraphQL operations.
- Soft-delete mismatch: local isDeleted/deletedAt vs cloud is_deleted.
- request_uid_text() cast risks in several RPCs (uuid cast without nullif).
- Admin provisioning depends on supabase_auth_admin role (not Nhost-native).
- Empty/placeholder migrations can break apply/rollback.
- Backup restore lacks ZIP path traversal safeguards and merge ignores account_id.

Acceptance Criteria for Later Phases
- Secrets removed from client and rotated; only safe runtime overrides remain.
- All core tables tracked in Hasura metadata with correct permissions.
- Cloud tables include is_deleted/deleted_at where required by SyncService.
- request_uid_text and RPCs are safe from invalid cast failures.
- Admin create owner/employee works reliably on Nhost.
- Migrations apply cleanly with no empty SQL failures.
- Backup restore prevents path traversal and merge is account-scoped.
