-- Restore prior implementation from 20251222180000_fix_fn_is_super_admin_claims_full.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  v_role text;
  v_uid_text text;
  v_uid uuid;
  v_email text := '';
  v_lookup_email text;
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

  v_role := NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.role', true),
      hasura_user ->> 'x-hasura-role',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-role',
      claims ->> 'x-hasura-role'
    ),
    ''
  );

  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  v_uid_text := COALESCE(
    hasura_user ->> 'x-hasura-user-id',
    current_setting('request.jwt.claim.sub', true),
    claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
    claims ->> 'x-hasura-user-id',
    claims ->> 'sub'
  );

  BEGIN
    v_uid := NULLIF(v_uid_text, '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  v_email := lower(
    COALESCE(
      hasura_user ->> 'x-hasura-user-email',
      current_setting('request.jwt.claim.email', true),
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'email',
      claims ->> 'x-hasura-user-email',
      claims ->> 'email',
      ''
    )
  );

  IF v_uid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.super_admins sa
      WHERE sa.user_uid = v_uid
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF v_email <> '' AND fn_is_super_admin_email(v_email) THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email)
      INTO v_lookup_email
      FROM auth.users u
     WHERE u.id = v_uid
     LIMIT 1;

    IF v_lookup_email IS NOT NULL AND fn_is_super_admin_email(v_lookup_email) THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO public;
