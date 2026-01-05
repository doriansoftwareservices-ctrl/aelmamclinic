BEGIN;

-- Restore permissive policies (rollback only).
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_read_service'
  ) THEN
    CREATE POLICY super_admins_read_service
    ON public.super_admins
    FOR SELECT
    TO public
    USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_write_service'
  ) THEN
    CREATE POLICY super_admins_write_service
    ON public.super_admins
    FOR ALL
    TO public
    USING (true)
    WITH CHECK (true);
  END IF;
END$$;

-- Restore unguarded sync RPCs (rollback only).
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
GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails(text[]) TO public;

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
GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) TO public;

COMMIT;
