BEGIN;

ALTER TABLE public.complaints
  ADD COLUMN IF NOT EXISTS reply_message text,
  ADD COLUMN IF NOT EXISTS replied_at timestamptz,
  ADD COLUMN IF NOT EXISTS replied_by uuid,
  ADD COLUMN IF NOT EXISTS handled_by uuid,
  ADD COLUMN IF NOT EXISTS handled_at timestamptz;

DROP FUNCTION IF EXISTS public.admin_reply_complaint(uuid, text, text);

CREATE OR REPLACE FUNCTION public.admin_reply_complaint(
  p_id uuid,
  p_reply text,
  p_status text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not_authenticated', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS NOT TRUE THEN
    RETURN QUERY SELECT false, 'super_admin_only', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_id IS NULL THEN
    RETURN QUERY SELECT false, 'missing_id', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE public.complaints
     SET reply_message = p_reply,
         replied_at = now(),
         replied_by = v_uid,
         handled_by = v_uid,
         handled_at = now(),
         status = COALESCE(NULLIF(trim(p_status), ''), status)
   WHERE id = p_id
   RETURNING account_id INTO v_account;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'not_found', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text, v_account, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
EXCEPTION WHEN others THEN
  RETURN QUERY SELECT false, sqlerrm, NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reply_complaint(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reply_complaint(uuid, text, text) TO public;

COMMIT;
