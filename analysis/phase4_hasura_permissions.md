# Phase 4 Hasura Permissions Hardening

## Goals
- Reduce data exposure from sensitive tables by tightening Hasura permissions.
- Preserve existing app flows by allowing superadmin access via role header.

## Metadata Changes
Updated `nhost/metadata/databases/default/tables/tables.yaml` for these tables:
- `account_users`: limit `me/user` to own rows (`user_uid = X-Hasura-User-Id`); write access only for superadmin.
- `profiles`: limit `me/user` to own rows (`id = X-Hasura-User-Id`); write access only for superadmin.
- `accounts`: access only for superadmin.
- `account_subscriptions`: access only for superadmin.
- `subscription_payments`: access only for superadmin.
- `subscription_requests`: limit `me/user` to own rows (`user_uid = X-Hasura-User-Id`); write access only for superadmin.
- `payment_methods`: `me/user` can read only `is_active = true`; write access only for superadmin.
- `subscription_plans`: `me/user` can read only `is_active = true`; write access only for superadmin.

## App Support Change (Superadmin Role)
Updated `lib/services/nhost_graphql_service.dart` to set `x-hasura-role: superadmin` for users who have the `superadmin` role in their Nhost session. This ensures admin screens can still access restricted tables after permission hardening.

## Notes
- These changes do not alter database RLS; they add a Hasura-level guard.
- If any superadmin account lacks the `superadmin` role in Nhost, they will not receive elevated table access.
