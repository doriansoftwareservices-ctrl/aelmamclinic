-- Restore prior behavior from 20251222100000_fix_fn_is_super_admin_gql.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT sa.*
  FROM public.super_admins sa
  WHERE public.fn_is_super_admin() = true
    AND (
      sa.user_uid = nullif(public.request_uid_text(), '')::uuid
      OR lower(sa.email) = lower(
        coalesce(current_setting('request.jwt.claims', true)::json ->> 'email', '')
      )
    )
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
