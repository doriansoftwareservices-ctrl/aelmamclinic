Phase 7 Migration Cleanup

Goal
- Prevent empty/placeholder migrations from failing apply/rollback.
- Keep historical migration order intact.

Changes
- Replaced empty SQL files with a safe no-op (SELECT 1).
- Normalized placeholder migrations to a safe no-op with a comment.

Affected Paths
- nhost/migrations/default/20250904_placeholder/up.sql
- nhost/migrations/default/20250904_placeholder/down.sql
- nhost/migrations/default/20250913000000_placeholder/up.sql
- nhost/migrations/default/20250913000000_placeholder/down.sql
- nhost/migrations/default/20250913000500_placeholder/up.sql
- nhost/migrations/default/20250913000500_placeholder/down.sql
- nhost/migrations/default/20250913001000_placeholder/up.sql
- nhost/migrations/default/20250913001000_placeholder/down.sql
- nhost/migrations/default/20251030000000_placeholder/up.sql
- nhost/migrations/default/20251030000000_placeholder/down.sql
- nhost/migrations/default/20251220130000_fix_jwt_claims_json_cast/down.sql
- nhost/migrations/default/20251220133000_update_fn_is_super_admin_gql_claims/down.sql
- nhost/migrations/default/20251220140000_fn_is_super_admin_gql_claims_fallback/down.sql
- nhost/migrations/default/20251220150000_fn_is_super_admin_gql_session_uid/down.sql
- nhost/migrations/default/20251220153000_fn_is_super_admin_gql_invoker/down.sql
