# Phase 0 Baseline (Snapshot vs Migrations)

- Snapshot: `server_snapshot_mergrgclboxflnucehgb_20260101_113109`
- Migrations scanned: `/mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic/nhost/migrations/default`
- Tracked functions (metadata): `31`

## Tracked Functions Return-Type Comparison

| Function | Snapshot returns | Migrations (latest) returns | Notes |
| --- | --- | --- | --- |
| `public.account_is_paid_gql` | `SETOF v_bool_result` | `SETOF public.v_bool_result` |  |
| `public.admin_approve_subscription_request` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_create_employee_full` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_create_owner_full` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_delete_clinic` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_list_clinics` | `SETOF v_admin_list_clinics` | `SETOF public.v_admin_list_clinics` |  |
| `public.admin_payment_stats` | `SETOF v_payment_stats` | `SETOF public.v_payment_stats` |  |
| `public.admin_payment_stats_by_day` | `SETOF v_payment_stats_by_day` | `SETOF public.v_payment_stats_by_day` |  |
| `public.admin_payment_stats_by_month` | `SETOF v_payment_stats_by_month` | `SETOF public.v_payment_stats_by_month` |  |
| `public.admin_payment_stats_by_plan` | `SETOF v_payment_stats_by_plan` | `SETOF public.v_payment_stats_by_plan` |  |
| `public.admin_reject_subscription_request` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_set_account_plan` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_set_clinic_frozen` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.admin_sync_super_admin_emails_gql` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.chat_accept_invitation` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.chat_admin_start_dm` | `SETOF v_uuid_result` | `SETOF public.v_uuid_result` |  |
| `public.chat_decline_invitation` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.chat_mark_delivered` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.create_subscription_request` | `SETOF v_uuid_result` | `uuid` | mismatch (file: nhost/migrations/default/20251228094500_secure_subscription_request_pricing/up.sql) |
| `public.debug_auth_context` | `SETOF v_debug_auth_context` | `SETOF public.v_debug_auth_context` |  |
| `public.delete_employee` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |
| `public.expire_account_subscriptions` | `SETOF v_rpc_result` | `integer` | mismatch (file: nhost/migrations/default/20251227020000_billing_hardening/up.sql) |
| `public.fn_is_super_admin_gql` | `SETOF v_is_super_admin` | `SETOF public.v_is_super_admin` |  |
| `public.list_employees_with_email` | `SETOF v_list_employees_with_email` | `SETOF public.v_list_employees_with_email` |  |
| `public.list_payment_methods` | `SETOF v_payment_methods` | `SETOF public.v_payment_methods` |  |
| `public.my_account_id` | `SETOF v_my_account_id` | `SETOF public.v_my_account_id` |  |
| `public.my_account_plan` | `SETOF v_my_account_plan` | `SETOF public.v_my_account_plan` |  |
| `public.my_feature_permissions` | `SETOF v_my_feature_permissions` | `SETOF public.v_my_feature_permissions` |  |
| `public.my_profile` | `SETOF v_my_profile` | `SETOF public.v_my_profile` |  |
| `public.self_create_account` | `SETOF v_uuid_result` | `uuid` | mismatch (file: nhost/migrations/default/20251227030000_self_create_account_hardening/up.sql) |
| `public.set_employee_disabled` | `SETOF v_rpc_result` | `SETOF public.v_rpc_result` |  |

## Mismatch Summary (Tracked Functions)
- Mismatched functions count: 3
- `public.create_subscription_request`
- `public.expire_account_subscriptions`
- `public.self_create_account`

## Missing in Migrations (Tracked Functions)
- None.

## Notes
- Comparison is normalized to ignore `public.` schema prefixes and case differences.
- “Latest” migration chosen by filename sort order in `nhost/migrations/default`.
- Snapshot remains the source of truth for deployed behavior.

## Phase 0 Actions (Freeze + Guardrails)
- Treat the snapshot as the canonical backend state until Phase 1 is applied.
- Do not run `nhost deploy` / apply migrations to production until return types are aligned.
- Any new migration touching tracked RPCs must be reviewed against the snapshot return types above.
