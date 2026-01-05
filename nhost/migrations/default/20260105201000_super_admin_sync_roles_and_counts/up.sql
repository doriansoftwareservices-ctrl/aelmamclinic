BEGIN;

-- Sync super admin emails and backfill auth roles/claims.
CREATE OR REPLACE FUNCTION public.admin_sync_super_admin_emails(p_emails text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text;
  normalized text;
  r record;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_emails IS NULL OR array_length(p_emails, 1) IS NULL THEN
    RETURN;
  END IF;

  FOREACH v_email IN ARRAY p_emails LOOP
    normalized := lower(coalesce(trim(v_email), ''));
    IF normalized = '' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.super_admins(email)
    VALUES (normalized)
    ON CONFLICT (email) DO NOTHING;
  END LOOP;

  UPDATE public.super_admins sa
     SET user_uid = u.id
    FROM auth.users u
   WHERE sa.user_uid IS NULL
     AND sa.email IS NOT NULL
     AND lower(sa.email) = lower(u.email);

  FOR r IN
    SELECT DISTINCT u.id
      FROM auth.users u
      JOIN public.super_admins sa
        ON (sa.user_uid IS NOT NULL AND sa.user_uid = u.id)
        OR (sa.email IS NOT NULL AND lower(sa.email) = lower(u.email))
  LOOP
    PERFORM public.auth_set_user_claims(r.id, 'superadmin', NULL::uuid);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_sync_super_admin_emails(text[]) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_sync_super_admin_emails_gql(
  p_emails text[]
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text;
  normalized text;
  r record;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_emails IS NULL OR array_length(p_emails, 1) IS NULL THEN
    RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid,
           NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  FOREACH v_email IN ARRAY p_emails LOOP
    normalized := lower(coalesce(trim(v_email), ''));
    IF normalized = '' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.super_admins(email)
    VALUES (normalized)
    ON CONFLICT (email) DO NOTHING;
  END LOOP;

  UPDATE public.super_admins sa
     SET user_uid = u.id
    FROM auth.users u
   WHERE sa.user_uid IS NULL
     AND sa.email IS NOT NULL
     AND lower(sa.email) = lower(u.email);

  FOR r IN
    SELECT DISTINCT u.id
      FROM auth.users u
      JOIN public.super_admins sa
        ON (sa.user_uid IS NOT NULL AND sa.user_uid = u.id)
        OR (sa.email IS NOT NULL AND lower(sa.email) = lower(u.email))
  LOOP
    PERFORM public.auth_set_user_claims(r.id, 'superadmin', NULL::uuid);
  END LOOP;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid,
         NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
    GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails(text[]) TO postgres;
    GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) TO postgres;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nhost') THEN
    GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails(text[]) TO nhost;
    GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) TO nhost;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nhost_auth_admin') THEN
    GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails(text[]) TO nhost_auth_admin;
    GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) TO nhost_auth_admin;
  END IF;
END$$;

-- Ensure "only active" member counts behave as expected.
CREATE OR REPLACE FUNCTION public.admin_dashboard_account_member_counts(
  hasura_session json,
  p_only_active boolean DEFAULT true
)
RETURNS SETOF public.v_admin_dashboard_account_member_counts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT
    au.account_id,
    a.name AS account_name,
    sum((lower(au.role) = 'owner')::int) AS owners_count,
    sum((lower(au.role) = 'admin')::int) AS admins_count,
    sum((lower(au.role) = 'employee')::int) AS employees_count,
    count(*) AS total_members
  FROM public.account_users au
  JOIN public.accounts a ON a.id = au.account_id
  WHERE (p_only_active IS DISTINCT FROM true)
     OR coalesce(au.disabled, false) = false
  GROUP BY au.account_id, a.name
  ORDER BY total_members DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) TO PUBLIC;

COMMIT;
