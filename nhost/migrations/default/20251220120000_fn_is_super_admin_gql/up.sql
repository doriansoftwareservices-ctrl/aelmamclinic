-- 20251220120000_fn_is_super_admin_gql.sql
-- GraphQL wrapper for fn_is_super_admin (returns table for Hasura).

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS TABLE (is_super_admin boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.fn_is_super_admin() AS is_super_admin;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO public;
