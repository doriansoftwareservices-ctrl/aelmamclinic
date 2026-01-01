# Phase 2 Auth Session Alignment

- Snapshot: `server_snapshot_mergrgclboxflnucehgb_20260101_113109`
- Repo metadata: `nhost/metadata/databases/default/functions/functions.yaml`
- Migrations: `/mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic/nhost/migrations/default`

## Snapshot metadata (session_argument)
- `public.debug_auth_context` → `hasura_session`
- `public.fn_is_super_admin_gql` → `hasura_session`
- `public.my_account_id` → `hasura_session`
- `public.my_profile` → `hasura_session`

## Repo metadata (session_argument)
- `public.debug_auth_context` → `hasura_session`
- `public.fn_is_super_admin_gql` → `hasura_session`
- `public.my_account_id` → `hasura_session`
- `public.my_profile` → `hasura_session`

## Latest migration signatures (args/returns)
- `public.debug_auth_context` args=(hasura_session json) returns=(SETOF public.v_debug_auth_context) | `nhost/migrations/default/20251231232204_use_session_argument_for_auth_rpcs/up.sql`
- `public.fn_is_super_admin_gql` args=(hasura_session json) returns=(SETOF public.v_is_super_admin) | `nhost/migrations/default/20251231232204_use_session_argument_for_auth_rpcs/up.sql`
- `public.my_account_id` args=(hasura_session json) returns=(SETOF public.v_my_account_id) | `nhost/migrations/default/20251231232204_use_session_argument_for_auth_rpcs/up.sql`
- `public.my_profile` args=(hasura_session json) returns=(SETOF public.v_my_profile) | `nhost/migrations/default/20251231232204_use_session_argument_for_auth_rpcs/up.sql`

## Result
- Snapshot and repo metadata both use `session_argument: hasura_session` for the auth RPCs.
- Latest migrations define these functions with `hasura_session json` args and `SETOF` view-backed returns.
- No further changes required for Phase 2.