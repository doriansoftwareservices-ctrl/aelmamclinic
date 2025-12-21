-- Restore prior fn_is_super_admin_gql implementation (returns super_admins rows).

DROP FUNCTION IF EXISTS public.fn_is_super_admin_gql();

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  uid_text text;
  uid uuid;
  v_email text;
BEGIN
  IF raw_hasura_user IS NOT NULL AND raw_hasura_user <> '' THEN
    BEGIN
      hasura_user := raw_hasura_user::jsonb;
    EXCEPTION WHEN others THEN
      hasura_user := '{}'::jsonb;
    END;
  END IF;

  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  uid_text := NULLIF(
    COALESCE(
      hasura_user ->> 'x-hasura-user-id',
      current_setting('request.jwt.claim.sub', true),
      claims ->> 'x-hasura-user-id',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
      claims ->> 'sub'
    ),
    ''
  );

  uid := NULLIF(uid_text, '')::uuid;

  v_email := NULLIF(
    COALESCE(
      hasura_user ->> 'x-hasura-user-email',
      current_setting('request.jwt.claim.email', true),
      claims ->> 'x-hasura-user-email',
      claims ->> 'email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'email'
    ),
    ''
  );

  RETURN QUERY
  SELECT sa.*
  FROM public.super_admins sa
  WHERE (uid IS NOT NULL AND sa.user_uid = uid)
     OR (v_email IS NOT NULL AND lower(sa.email) = lower(v_email))
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
