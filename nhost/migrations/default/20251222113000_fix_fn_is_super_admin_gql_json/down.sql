-- Restore JSON-cast-based implementation (may fail on invalid claims).

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH claims AS (
    SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb AS data
  ),
  resolved AS (
    SELECT
      COALESCE(
        data ->> 'x-hasura-user-id',
        data -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
        data ->> 'sub'
      ) AS user_id,
      COALESCE(
        data ->> 'email',
        data -> 'https://hasura.io/jwt/claims' ->> 'email'
      ) AS email
    FROM claims
  )
  SELECT sa.*
  FROM public.super_admins sa, resolved r
  WHERE public.fn_is_super_admin() = true
    AND (
      sa.user_uid = NULLIF(r.user_id, '')::uuid
      OR lower(sa.email) = lower(NULLIF(r.email, ''))
    )
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
