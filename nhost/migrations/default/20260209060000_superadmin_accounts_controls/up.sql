BEGIN;

-- Root super admin helper (locked to a single email).
CREATE OR REPLACE FUNCTION public.fn_is_root_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  raw_claims text := current_setting('request.jwt.claims', true);
  claims jsonb := '{}'::jsonb;
  v_email text := '';
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

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

  RETURN v_email = 'elmam.clinic.c.s@elmam.com';
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_root_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_root_super_admin() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_root_super_admin() TO public;

-- Tabs permissions for admin dashboard visibility.
CREATE TABLE IF NOT EXISTS public.super_admin_tab_permissions (
  user_uid uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  allowed_tabs text[] NOT NULL DEFAULT ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Composite return types for Hasura tracking.
CREATE OR REPLACE VIEW public.v_super_admin_tabs AS
SELECT NULL::text[] AS allowed_tabs
WHERE false;

CREATE OR REPLACE VIEW public.v_super_admin_account AS
SELECT
  NULL::text AS email,
  NULL::uuid AS user_uid,
  NULL::timestamptz AS created_at,
  NULL::boolean AS disabled,
  NULL::text AS default_role,
  NULL::text[] AS allowed_tabs,
  NULL::boolean AS has_user
WHERE false;

ALTER TABLE public.super_admin_tab_permissions ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='super_admin_tab_permissions'
      AND policyname='super_admin_tabs_select_self_or_root'
  ) THEN
    CREATE POLICY super_admin_tabs_select_self_or_root
    ON public.super_admin_tab_permissions
    FOR SELECT TO PUBLIC
    USING (
      user_uid = nullif(public.request_uid_text(), '')::uuid
      OR public.fn_is_root_super_admin() = true
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='super_admin_tab_permissions'
      AND policyname='super_admin_tabs_write_root'
  ) THEN
    CREATE POLICY super_admin_tabs_write_root
    ON public.super_admin_tab_permissions
    FOR INSERT TO PUBLIC
    WITH CHECK (public.fn_is_root_super_admin() = true);
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='super_admin_tab_permissions'
      AND policyname='super_admin_tabs_update_root'
  ) THEN
    CREATE POLICY super_admin_tabs_update_root
    ON public.super_admin_tab_permissions
    FOR UPDATE TO PUBLIC
    USING (public.fn_is_root_super_admin() = true)
    WITH CHECK (public.fn_is_root_super_admin() = true);
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='super_admin_tab_permissions'
      AND policyname='super_admin_tabs_delete_root'
  ) THEN
    CREATE POLICY super_admin_tabs_delete_root
    ON public.super_admin_tab_permissions
    FOR DELETE TO PUBLIC
    USING (public.fn_is_root_super_admin() = true);
  END IF;
END$$;

-- Allow root super admin to read all super_admins rows.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='super_admins'
      AND policyname='super_admins_select_root'
  ) THEN
    CREATE POLICY super_admins_select_root
    ON public.super_admins
    FOR SELECT TO PUBLIC
    USING (public.fn_is_root_super_admin() = true);
  END IF;
END$$;

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
  v_uid := nullif(public.request_uid_text(), '')::uuid;
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
GRANT EXECUTE ON FUNCTION public.admin_get_super_admin_tabs() TO public;

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
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO public;

-- Update allowed tabs for a super admin (root only).
CREATE OR REPLACE FUNCTION public.admin_set_super_admin_tabs(
  p_user_uid uuid,
  p_allowed_tabs text[]
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_allowed text[];
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_user_uid IS NULL THEN
    RETURN QUERY SELECT false, 'missing user', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT array_agg(x)
  INTO v_allowed
  FROM (
    SELECT DISTINCT lower(trim(t)) AS x
    FROM unnest(coalesce(p_allowed_tabs, '{}'::text[])) t
    WHERE lower(trim(t)) IN (
      'clinics','chats','subscriptions','payments','complaints','stats','members'
    )
  ) s;

  IF v_allowed IS NULL OR array_length(v_allowed, 1) IS NULL THEN
    v_allowed := v_default;
  END IF;

  INSERT INTO public.super_admin_tab_permissions(user_uid, allowed_tabs, updated_at)
  VALUES (p_user_uid, v_allowed, now())
  ON CONFLICT (user_uid) DO UPDATE
  SET allowed_tabs = excluded.allowed_tabs,
      updated_at = excluded.updated_at;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, p_user_uid, NULL::uuid,
    NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_super_admin_tabs(uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_super_admin_tabs(uuid, text[]) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_super_admin_tabs(uuid, text[]) TO public;

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
GRANT EXECUTE ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) TO public;

-- Delete a super admin account (root only).
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

    DELETE FROM auth.users
    WHERE id = v_uid;
  END IF;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_delete_super_admin(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_super_admin(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_super_admin(text) TO public;

COMMIT;
