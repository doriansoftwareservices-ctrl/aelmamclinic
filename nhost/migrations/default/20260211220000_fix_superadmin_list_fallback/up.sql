BEGIN;

-- Ensure whitelist contains all existing super_admins emails (needed by guard_superadmin_role).
INSERT INTO public.superadmin_whitelist(email)
SELECT lower(sa.email)
FROM public.super_admins sa
WHERE sa.email IS NOT NULL AND sa.email <> ''
ON CONFLICT (email) DO NOTHING;

-- Ensure root is whitelisted.
INSERT INTO public.superadmin_whitelist(email)
VALUES (lower('elmam.clinic.c.s@elmam.com'))
ON CONFLICT (email) DO NOTHING;

-- Sync auth.user_roles for any super_admins (if table exists).
DO $$
DECLARE
  r record;
BEGIN
  IF to_regclass('auth.user_roles') IS NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT u.id AS user_id, lower(u.email::text) AS email
    FROM public.super_admins sa
    JOIN auth.users u
      ON sa.user_uid = u.id OR lower(sa.email) = lower(u.email::text)
  LOOP
    -- Only insert if whitelisted (guard_superadmin_role trigger enforces this).
    IF EXISTS (SELECT 1 FROM public.superadmin_whitelist w WHERE w.email = r.email) THEN
      INSERT INTO auth.user_roles(user_id, role)
      SELECT r.user_id, 'superadmin'
      WHERE NOT EXISTS (
        SELECT 1 FROM auth.user_roles ur
        WHERE ur.user_id = r.user_id AND ur.role = 'superadmin'
      );
    END IF;
  END LOOP;
END $$;

-- List superadmins with fallback to public.super_admins if auth.user_roles is empty.
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

  -- If auth.user_roles is absent or empty, fall back to public.super_admins.
  IF to_regclass('auth.user_roles') IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.user_roles WHERE role = 'superadmin'
  ) THEN
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
  ORDER BY coalesce(sa.created_at, u.created_at) DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;

COMMIT;
