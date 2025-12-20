-- 20251220133000_update_fn_is_super_admin_gql_claims.sql
-- Use Hasura JWT claims (x-hasura-user-id) to resolve the current user.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT sa.*
  FROM public.super_admins sa
  WHERE sa.user_uid =
    NULLIF(
      (
        nullif(current_setting('request.jwt.claims', true), '')::jsonb
          -> 'https://hasura.io/jwt/claims'
          ->> 'x-hasura-user-id'
      ),
      ''
    )::uuid;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
