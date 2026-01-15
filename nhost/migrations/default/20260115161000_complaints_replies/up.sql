BEGIN;

ALTER TABLE public.complaints
  ADD COLUMN IF NOT EXISTS reply_message text,
  ADD COLUMN IF NOT EXISTS replied_at timestamptz,
  ADD COLUMN IF NOT EXISTS replied_by uuid;

CREATE OR REPLACE FUNCTION public.admin_reply_complaint(
  p_id uuid,
  p_reply text,
  p_status text DEFAULT NULL
)
RETURNS TABLE(ok boolean, error text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not_authenticated';
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS NOT TRUE THEN
    RETURN QUERY SELECT false, 'super_admin_only';
    RETURN;
  END IF;

  IF p_id IS NULL THEN
    RETURN QUERY SELECT false, 'missing_id';
    RETURN;
  END IF;

  UPDATE public.complaints
     SET reply_message = p_reply,
         replied_at = now(),
         replied_by = v_uid,
         handled_by = v_uid,
         handled_at = now(),
         status = COALESCE(NULLIF(trim(p_status), ''), status)
   WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'not_found';
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reply_complaint(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reply_complaint(uuid, text, text) TO public;

COMMIT;
