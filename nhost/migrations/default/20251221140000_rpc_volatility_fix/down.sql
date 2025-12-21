-- 20251221140000_rpc_volatility_fix
-- Revert query RPCs back to VOLATILE (legacy behavior).

ALTER FUNCTION public.admin_list_clinics() VOLATILE;
ALTER FUNCTION public.list_employees_with_email(uuid) VOLATILE;
ALTER FUNCTION public.my_feature_permissions(uuid) VOLATILE;
ALTER FUNCTION public.my_account_id() VOLATILE;
ALTER FUNCTION public.my_profile() VOLATILE;
ALTER FUNCTION public.my_accounts() VOLATILE;
