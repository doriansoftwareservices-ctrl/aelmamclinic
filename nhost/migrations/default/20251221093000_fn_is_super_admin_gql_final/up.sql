-- 20251221093000_fn_is_super_admin_gql_final
-- Finalize fn_is_super_admin_gql as SECURITY INVOKER and rely on Hasura perms.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT * FROM public.super_admins;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
