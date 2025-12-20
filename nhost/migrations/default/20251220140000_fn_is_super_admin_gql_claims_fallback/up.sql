-- 20251220140000_fn_is_super_admin_gql_claims_fallback.sql
-- Support both top-level and nested Hasura claims paths.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH claims AS (
    SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb AS data
  ),
  uid AS (
    SELECT COALESCE(
      data ->> 'x-hasura-user-id',
      data -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id'
    ) AS user_id
    FROM claims
  )
  SELECT sa.*
  FROM public.super_admins sa
  WHERE sa.user_uid = NULLIF((SELECT user_id FROM uid), '')::uuid;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
