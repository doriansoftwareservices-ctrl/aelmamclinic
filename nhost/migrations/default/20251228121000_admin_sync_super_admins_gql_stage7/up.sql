-- GraphQL-friendly wrapper for syncing super-admin emails.

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
REVOKE ALL ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails_gql(text[]) TO public;
