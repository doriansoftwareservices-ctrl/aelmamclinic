BEGIN;

-- Harden superadmin checks (avoid JSON cast failures + prefer auth.users email).
CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text := current_setting('request.jwt.claim.role', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  claims jsonb := '{}'::jsonb;
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := '';
  v_lookup_email text;
BEGIN
  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  v_email := lower(
    coalesce(
      public.request_email_text(),
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'email',
      claims ->> 'email',
      ''
    )
  );

  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL THEN
    IF exists (
      select 1
        from public.super_admins sa
       where sa.user_uid = v_uid
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF v_email <> '' THEN
    IF exists (
      select 1
        from public.super_admins sa
       where lower(sa.email) = v_email
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF v_uid IS NOT NULL THEN
    select lower(u.email)
      into v_lookup_email
      from auth.users u
     where u.id = v_uid
     limit 1;

    IF v_lookup_email IS NOT NULL THEN
      IF exists (
        select 1
          from public.super_admins sa
         where lower(sa.email) = v_lookup_email
      ) THEN
        RETURN true;
      END IF;
    END IF;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.fn_is_root_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := '';
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

  IF v_uid IS NOT NULL THEN
    select lower(u.email)
      into v_email
      from auth.users u
     where u.id = v_uid
     limit 1;
  END IF;

  v_email := lower(
    coalesce(
      v_email,
      public.request_email_text(),
      ''
    )
  );

  RETURN v_email = 'elmam.clinic.c.s@elmam.com';
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_root_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_root_super_admin() TO PUBLIC;

-- Fetch allowed tabs for the current super admin.
CREATE OR REPLACE FUNCTION public.admin_get_super_admin_tabs()
RETURNS SETOF public.v_super_admin_tabs
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid;
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF public.fn_is_root_super_admin() = true THEN
    RETURN QUERY SELECT v_default;
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
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

-- List super admins (root only).
CREATE OR REPLACE FUNCTION public.admin_list_super_admin_accounts()
RETURNS SETOF public.v_super_admin_account
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    sa.email,
    coalesce(sa.user_uid, u.id) AS user_uid,
    sa.created_at,
    coalesce(u.disabled, false) AS disabled,
    coalesce(u.default_role, 'user') AS default_role,
    coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
    (u.id IS NOT NULL) AS has_user
  FROM public.super_admins sa
  LEFT JOIN auth.users u
    ON u.id = sa.user_uid OR lower(u.email) = lower(sa.email)
  LEFT JOIN public.super_admin_tab_permissions p
    ON p.user_uid = u.id
  ORDER BY sa.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;

-- Disable or enable a super admin account (root only).
CREATE OR REPLACE FUNCTION public.admin_set_super_admin_disabled(
  p_email text,
  p_disabled boolean
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := lower(coalesce(trim(p_email), ''));
  v_uid uuid;
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_email = '' THEN
    RETURN QUERY SELECT false, 'missing email', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_email = 'elmam.clinic.c.s@elmam.com' THEN
    RETURN QUERY SELECT false, 'cannot disable root super admin',
      NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT u.id INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'user not found', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE auth.users
  SET disabled = coalesce(p_disabled, false)
  WHERE id = v_uid;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, coalesce(p_disabled, false);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) TO PUBLIC;

-- Delete a super admin account (root only, safe: disable + remove role).
CREATE OR REPLACE FUNCTION public.admin_delete_super_admin(
  p_email text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := lower(coalesce(trim(p_email), ''));
  v_uid uuid;
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_email = '' THEN
    RETURN QUERY SELECT false, 'missing email', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_email = 'elmam.clinic.c.s@elmam.com' THEN
    RETURN QUERY SELECT false, 'cannot delete root super admin',
      NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT u.id INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  DELETE FROM public.super_admins
  WHERE lower(email) = v_email;

  IF v_uid IS NOT NULL THEN
    DELETE FROM public.super_admin_tab_permissions
    WHERE user_uid = v_uid;

    BEGIN
      DELETE FROM auth.user_roles
      WHERE user_id = v_uid AND role = 'superadmin';
    EXCEPTION WHEN undefined_column THEN
      BEGIN
        DELETE FROM auth.user_roles
        WHERE "userId" = v_uid AND role = 'superadmin';
      EXCEPTION WHEN others THEN
        NULL;
      END;
    END;

    UPDATE auth.users
    SET disabled = true
    WHERE id = v_uid;
  END IF;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_super_admin(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_super_admin(text) TO PUBLIC;

COMMIT;
