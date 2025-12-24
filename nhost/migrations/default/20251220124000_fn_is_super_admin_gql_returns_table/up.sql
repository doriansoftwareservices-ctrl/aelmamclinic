-- 20251220124000_fn_is_super_admin_gql_returns_table.sql
-- Make the GraphQL wrapper return SETOF a table so Hasura can track it.

DROP FUNCTION IF EXISTS public.fn_is_super_admin_gql();

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT sa.*
  FROM public.super_admins sa
  WHERE sa.user_uid = nullif(public.request_uid_text(), '')::uuid
     OR (sa.user_uid IS NULL AND lower(sa.email) =
         lower(coalesce(current_setting('request.jwt.claims', true)::json ->> 'email', '')))
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
