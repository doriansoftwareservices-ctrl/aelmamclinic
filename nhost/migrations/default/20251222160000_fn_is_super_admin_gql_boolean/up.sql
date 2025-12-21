-- Expose fn_is_super_admin as a table-returning function for GraphQL.

DROP FUNCTION IF EXISTS public.fn_is_super_admin_gql();

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS TABLE (is_super_admin boolean)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT public.fn_is_super_admin() AS is_super_admin;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
