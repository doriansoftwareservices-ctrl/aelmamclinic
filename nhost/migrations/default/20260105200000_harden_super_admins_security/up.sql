BEGIN;

-- Harden super_admins policies: remove permissive service policies.
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS super_admins_read_service ON public.super_admins;
DROP POLICY IF EXISTS super_admins_write_service ON public.super_admins;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_select_self'
  ) THEN
    CREATE POLICY super_admins_select_self
    ON public.super_admins
    FOR SELECT
    TO PUBLIC
    USING (user_uid = nullif(public.request_uid_text(), '')::uuid);
  END IF;
END$$;

-- Lock down super admin sync RPCs to super admins only.
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

COMMIT;
