BEGIN;

-- Ensure root has superadmin role in auth.user_roles (if table exists)
DO $$
DECLARE
  v_root_uid uuid;
BEGIN
  IF to_regclass('auth.users') IS NULL OR to_regclass('auth.user_roles') IS NULL THEN
    RETURN;
  END IF;

  SELECT u.id INTO v_root_uid
  FROM auth.users u
  WHERE lower((u.email)::text) = lower('elmam.clinic.c.s@elmam.com')
  LIMIT 1;

  IF v_root_uid IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO auth.user_roles(user_id, role)
  SELECT v_root_uid, 'superadmin'
  WHERE NOT EXISTS (
    SELECT 1
    FROM auth.user_roles ur
    WHERE ur.user_id = v_root_uid
      AND ur.role = 'superadmin'
  );
END $$;

-- Make list function robust if auth.user_roles is empty
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
  IF public.admin_is_root_email() IS DISTINCT FROM true THEN
    RETURN;
  END IF;

  IF to_regclass('auth.user_roles') IS NULL THEN
    RETURN QUERY
    SELECT
      lower((u.email)::text) AS email,
      u.id AS user_uid,
      coalesce(sa.created_at, u.created_at) AS created_at,
      coalesce(sa.disabled, u.disabled, false) AS disabled,
      coalesce(sa.default_role, 'superadmin') AS default_role,
      coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
      true AS has_user
    FROM public.super_admins sa
    JOIN auth.users u
      ON sa.user_uid = u.id OR lower(sa.email) = lower((u.email)::text)
    LEFT JOIN public.super_admin_tab_permissions p
      ON p.user_uid = u.id
    ORDER BY coalesce(sa.created_at, u.created_at) DESC;
    RETURN;
  END IF;

  RETURN QUERY
  WITH sa_users AS (
    SELECT
      lower((u.email)::text) AS email,
      u.id AS user_uid,
      coalesce(sa.created_at, u.created_at) AS created_at,
      coalesce(sa.disabled, u.disabled, false) AS disabled,
      coalesce(sa.default_role, 'superadmin') AS default_role,
      coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
      true AS has_user
    FROM public.super_admins sa
    JOIN auth.users u
      ON sa.user_uid = u.id OR lower(sa.email) = lower((u.email)::text)
    LEFT JOIN public.super_admin_tab_permissions p
      ON p.user_uid = u.id
  )
  SELECT
    lower((u.email)::text) AS email,
    u.id AS user_uid,
    coalesce(sa.created_at, u.created_at) AS created_at,
    coalesce(sa.disabled, u.disabled, false) AS disabled,
    coalesce(sa.default_role, 'superadmin') AS default_role,
    coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
    true AS has_user
  FROM auth.user_roles ur
  JOIN auth.users u
    ON u.id = ur.user_id
  LEFT JOIN public.super_admins sa
    ON sa.user_uid = u.id OR lower(sa.email) = lower((u.email)::text)
  LEFT JOIN public.super_admin_tab_permissions p
    ON p.user_uid = u.id
  WHERE ur.role = 'superadmin'

  UNION ALL
  SELECT *
  FROM sa_users s
  WHERE NOT EXISTS (
    SELECT 1
    FROM auth.user_roles ur
    WHERE ur.user_id = s.user_uid
      AND ur.role = 'superadmin'
  )
  ORDER BY created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;

COMMIT;
