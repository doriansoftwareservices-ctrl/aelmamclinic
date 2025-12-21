-- Expose fn_is_super_admin_gql via a view-backed return type for Hasura.

CREATE OR REPLACE VIEW public.v_is_super_admin AS
SELECT NULL::boolean AS is_super_admin
WHERE false;

DROP FUNCTION IF EXISTS public.fn_is_super_admin_gql();

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.v_is_super_admin
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT public.fn_is_super_admin() AS is_super_admin;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
