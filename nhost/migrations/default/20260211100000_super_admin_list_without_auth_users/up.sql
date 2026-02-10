BEGIN;

ALTER TABLE public.super_admins
  ADD COLUMN IF NOT EXISTS disabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.super_admins
  ADD COLUMN IF NOT EXISTS default_role text NOT NULL DEFAULT 'user';

ALTER TABLE public.super_admins
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- Keep existing rows normalized.
UPDATE public.super_admins
SET disabled = coalesce(disabled, false),
    default_role = coalesce(nullif(default_role, ''), 'user'),
    updated_at = now();

-- Root-only helper via claims email (avoid auth.users read).
CREATE OR REPLACE FUNCTION public.admin_is_root_email()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claims jsonb;
  v_email text := '';
BEGIN
  v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_email := lower(trim(coalesce(
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-user-email}',
    ''
  )));
  RETURN v_email = 'elmam.clinic.c.s@elmam.com';
END;
$$;
REVOKE ALL ON FUNCTION public.admin_is_root_email() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_is_root_email() TO PUBLIC;

-- Root-only: list super admins without touching auth.users.
CREATE OR REPLACE FUNCTION public.admin_list_super_admin_accounts()
RETURNS SETOF public.v_super_admin_account
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF public.admin_is_root_email() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    sa.email,
    sa.user_uid,
    sa.created_at,
    sa.disabled,
    sa.default_role,
    coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
    (sa.user_uid IS NOT NULL) AS has_user
  FROM public.super_admins sa
  LEFT JOIN public.super_admin_tab_permissions p
    ON p.user_uid = sa.user_uid
  ORDER BY sa.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;

-- Root-only: disable or enable a super admin (avoid auth.users read if missing).
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
  IF public.admin_is_root_email() IS DISTINCT FROM true THEN
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

  UPDATE public.super_admins
  SET disabled = coalesce(p_disabled, false),
      updated_at = now()
  WHERE lower(email) = v_email;

  SELECT sa.user_uid INTO v_uid
  FROM public.super_admins sa
  WHERE lower(sa.email) = v_email
  LIMIT 1;

  IF v_uid IS NOT NULL THEN
    BEGIN
      UPDATE auth.users
      SET disabled = coalesce(p_disabled, false)
      WHERE id = v_uid;
    EXCEPTION WHEN others THEN
      -- ignore auth.users permission issues
      NULL;
    END;
  END IF;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, coalesce(p_disabled, false);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) TO PUBLIC;

-- Root-only: delete a super admin (avoid auth.users read; use stored uid).
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
  IF public.admin_is_root_email() IS DISTINCT FROM true THEN
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

  SELECT sa.user_uid INTO v_uid
  FROM public.super_admins sa
  WHERE lower(sa.email) = v_email
  LIMIT 1;

  DELETE FROM public.super_admins
  WHERE lower(email) = v_email;

  IF v_uid IS NOT NULL THEN
    DELETE FROM public.super_admin_tab_permissions
    WHERE user_uid = v_uid;

    BEGIN
      DELETE FROM auth.users
      WHERE id = v_uid;
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_delete_super_admin(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_super_admin(text) TO PUBLIC;

-- Root-only: read tabs without auth.users.
CREATE OR REPLACE FUNCTION public.admin_get_super_admin_tabs()
RETURNS SETOF public.v_super_admin_tabs
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_email text := '';
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  v_email := lower(trim(coalesce(
    current_setting('request.jwt.claims', true)::jsonb #>> '{https://hasura.io/jwt/claims,x-hasura-user-email}',
    ''
  )));

  IF v_uid IS NULL AND v_email = '' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE (v_uid IS NOT NULL AND sa.user_uid = v_uid)
       OR (v_email <> '' AND lower(sa.email) = v_email)
  ) THEN
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

COMMIT;
