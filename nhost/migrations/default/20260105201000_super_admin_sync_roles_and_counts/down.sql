BEGIN;

-- Restore prior guarded sync behavior without role backfill.
CREATE OR REPLACE FUNCTION public.admin_sync_super_admin_emails(p_emails text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  normalized text;
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
END;
$$;
REVOKE ALL ON FUNCTION public.admin_sync_super_admin_emails(text[]) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_sync_super_admin_emails_gql(
  p_emails text[]
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  normalized text;
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

-- Restore member counts function that relies on the view filter.
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
  SELECT *
  FROM public.v_admin_dashboard_account_member_counts
  WHERE (p_only_active IS DISTINCT FROM true)
     OR account_id IN (
       SELECT account_id FROM public.account_users WHERE coalesce(disabled, false) = false
     )
  ORDER BY total_members DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) TO PUBLIC;

COMMIT;
