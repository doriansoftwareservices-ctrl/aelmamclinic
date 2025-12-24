-- 20251031100500_account_users_policy_fix.sql
-- Fix account_users policy recursion by introducing a helper membership function.

CREATE OR REPLACE FUNCTION public.fn_is_account_member(p_account uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid::text = public.request_uid_text()::text
      AND coalesce(au.disabled, false) = false
  );
$$;

REVOKE ALL ON FUNCTION public.fn_is_account_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_member(uuid) TO PUBLIC;

DROP POLICY IF EXISTS account_users_select ON public.account_users;

CREATE POLICY account_users_select
ON public.account_users
FOR SELECT
TO PUBLIC
USING (
  fn_is_super_admin() = true
  OR account_users.user_uid::text = public.request_uid_text()::text
  OR fn_is_account_member(account_users.account_id)
);

