-- Make fn_is_super_admin_gql robust against invalid JSON in request.jwt.claims.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  raw_claims text := current_setting('request.jwt.claims', true);
  data jsonb := '{}'::jsonb;
  user_id text;
  email text;
BEGIN
  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      data := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      data := '{}'::jsonb;
    END;
  END IF;

  user_id := COALESCE(
    data ->> 'x-hasura-user-id',
    data -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
    data ->> 'sub'
  );

  email := COALESCE(
    data ->> 'email',
    data -> 'https://hasura.io/jwt/claims' ->> 'email'
  );

  RETURN QUERY
  SELECT sa.*
  FROM public.super_admins sa
  WHERE public.fn_is_super_admin() = true
    AND (
      sa.user_uid = NULLIF(user_id, '')::uuid
      OR lower(sa.email) = lower(NULLIF(email, ''))
    )
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
