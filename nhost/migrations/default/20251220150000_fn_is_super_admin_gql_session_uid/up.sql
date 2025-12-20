-- 20251220150000_fn_is_super_admin_gql_session_uid.sql
-- Prefer Hasura session variable x-hasura-user-id, with JWT fallbacks.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH raw AS (
    SELECT
      NULLIF(current_setting('request.session.x-hasura-user-id', true), '') AS session_uid,
      NULLIF(current_setting('request.jwt.claims', true), '')::jsonb AS claims
  ),
  uid AS (
    SELECT COALESCE(
      session_uid,
      claims ->> 'x-hasura-user-id',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
      claims ->> 'sub'
    ) AS user_id
    FROM raw
  )
  SELECT sa.*
  FROM public.super_admins sa
  WHERE sa.user_uid = NULLIF((SELECT user_id FROM uid), '')::uuid;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
