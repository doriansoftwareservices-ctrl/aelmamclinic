Phase 6 Admin Provisioning Alignment

Goal
- Remove reliance on non-Nhost roles (supabase_auth_admin) inside database functions.
- Ensure admin provisioning uses Edge Functions + Nhost Auth Admin API only.

Change
- admin_resolve_or_create_auth_user no longer tries to create auth users in SQL.
- The function now requires the auth user to exist and raises a clear error if not.
- Edge Functions (admin-create-owner/admin-create-employee) already create or fetch the auth user before calling GraphQL.

Updated File
- nhost/migrations/default/20251123010000_fix_admin_provisioning_and_membership/up.sql

Operational Notes
- Provisioning must be performed via the Edge Functions so the auth user exists.
- Any direct GraphQL call to admin_create_owner_full/admin_create_employee_full must pre-create the auth user.
