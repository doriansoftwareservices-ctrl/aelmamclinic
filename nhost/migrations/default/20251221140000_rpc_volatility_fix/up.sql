-- 20251221140000_rpc_volatility_fix
-- Ensure query RPCs are STABLE so Hasura exposes them under query_root.

ALTER FUNCTION public.admin_list_clinics() STABLE;
ALTER FUNCTION public.list_employees_with_email(uuid) STABLE;
ALTER FUNCTION public.my_feature_permissions(uuid) STABLE;
ALTER FUNCTION public.my_account_id() STABLE;
ALTER FUNCTION public.my_profile() STABLE;
ALTER FUNCTION public.my_accounts() STABLE;
