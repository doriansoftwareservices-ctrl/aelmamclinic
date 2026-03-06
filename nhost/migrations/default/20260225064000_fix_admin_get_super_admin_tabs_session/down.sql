BEGIN;

-- Revert to v4 implementation (no session argument)
CREATE OR REPLACE FUNCTION public.admin_get_super_admin_tabs()
RETURNS SETOF public.v_super_admin_tabs
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_claims jsonb := '{}'::jsonb;
  v_uid_text text := '';
  v_uid uuid;
  v_email text := '';
  v_role text := '';
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
  v_has_admin boolean := false;
BEGIN
  BEGIN
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_claims := '{}'::jsonb;
  END;

  v_role := lower(trim(coalesce(
    current_setting('request.jwt.claim.role', true),
    current_setting('request.header.x-hasura-role', true),
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-role}',
    v_claims #>> '{x-hasura-role}',
    ''
  )));

  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  v_uid_text := coalesce(
    current_setting('request.header.x-hasura-user-id', true),
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-user-id}',
    v_claims #>> '{x-hasura-user-id}',
    v_claims ->> 'sub',
    ''
  );

  IF v_uid IS NULL AND v_uid_text <> '' THEN
    BEGIN
      v_uid := v_uid_text::uuid;
    EXCEPTION WHEN others THEN
      v_uid := NULL;
    END;
  END IF;

  v_email := lower(trim(coalesce(
    public.request_email_text(),
    current_setting('request.header.x-hasura-user-email', true),
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-user-email}',
    v_claims #>> '{https://hasura.io/jwt/claims,email}',
    v_claims ->> 'email',
    ''
  )));

  IF v_role <> 'superadmin' THEN
    RETURN;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT true INTO v_has_admin
    FROM public.super_admins sa
    WHERE sa.user_uid = v_uid
    LIMIT 1;
  END IF;

  IF v_has_admin IS DISTINCT FROM true AND v_email <> '' THEN
    SELECT true INTO v_has_admin
    FROM public.super_admins sa
    WHERE lower(sa.email) = v_email
    LIMIT 1;
  END IF;

  IF v_has_admin IS DISTINCT FROM true THEN
    RETURN;
  END IF;

  IF v_uid IS NULL AND v_email <> '' THEN
    SELECT u.id INTO v_uid
    FROM auth.users u
    WHERE lower(u.email) = v_email
    LIMIT 1;
  END IF;

  IF v_uid IS NULL THEN
    RETURN QUERY SELECT v_default;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT coalesce(p.allowed_tabs, v_default)
  FROM public.super_admin_tab_permissions p
  WHERE p.user_uid = v_uid;

  IF NOT FOUND THEN
    RETURN QUERY SELECT v_default;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_super_admin_tabs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_super_admin_tabs() TO PUBLIC;

COMMIT;
