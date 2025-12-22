# Phase 6 Verification Plan

This checklist validates the unified super-admin model and the updated permissions.
Run SQL steps using a service-role session in Supabase Studio.

## A) Data audit (SQL)
Run:
`supabase/diagnostics/phase6_audit.sql`

Expected results:
- Queries 1-4 return zero rows.
- Query 5 returns zero rows (each account has an owner).
- Queries 6-9 return zero rows or only known legacy exceptions.

## B) Super admin validation
1) Ensure each super admin has a `super_admins.user_uid` row.
2) Sign in with a super admin user.
3) Confirm:
   - Admin dashboard opens directly.
   - Creating clinic owner works.
   - Creating employee works.
   - Freezing/deleting a clinic works.

## C) Owner validation
1) Sign in as a clinic owner.
2) Confirm:
   - Owner can view full clinic scope.
   - Owner can create/disable/delete employees.
   - Owner can update clinic metadata (accounts update policy).
   - Owner can view audit logs.

## D) Employee validation
1) Sign in as an employee with limited features.
2) Confirm:
   - Only permitted features appear.
   - Employee cannot manage users or clinic settings.
   - Audit logs are not accessible.

## E) Feature permissions RPC
1) From a non-super user, call:
   - `my_feature_permissions(p_account := <account_id>)`
2) Ensure it returns the expected allowed features and CRUD flags.
3) Call `my_feature_permissions()` without params as a sanity check.

## F) Regression checks
- Verify chat admin DM initiation works for super admin.
- Verify RLS on accounts/account_users still allows read for members.
