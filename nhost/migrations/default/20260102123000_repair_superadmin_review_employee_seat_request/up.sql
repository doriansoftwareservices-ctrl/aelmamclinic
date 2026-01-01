-- Ensure superadmin_review_employee_seat_request exists with expected signature.
DROP FUNCTION IF EXISTS public.superadmin_review_employee_seat_request(uuid, boolean, text);

CREATE OR REPLACE FUNCTION public.superadmin_review_employee_seat_request(
  p_request_id uuid,
  p_approve boolean,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_request record;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_request
    FROM public.employee_seat_requests r
   WHERE r.id = p_request_id
   LIMIT 1;

  IF v_request.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_approve IS TRUE THEN
    UPDATE public.employee_seat_requests
       SET status = 'approved',
           admin_note = NULLIF(trim(coalesce(p_note, '')), ''),
           updated_at = now()
     WHERE id = p_request_id;

    UPDATE public.account_users
       SET disabled = false,
           updated_at = now()
     WHERE account_id = v_request.account_id
       AND user_uid = v_request.employee_user_uid;

    UPDATE public.profiles
       SET disabled = false,
           updated_at = now()
     WHERE id = v_request.employee_user_uid;

    PERFORM public.auth_set_user_claims(
      v_request.employee_user_uid,
      'employee',
      v_request.account_id
    );

    RETURN QUERY SELECT true, NULL::text, v_request.account_id, v_request.employee_user_uid, NULL::uuid, 'employee', NULL::boolean, false;
  ELSE
    UPDATE public.employee_seat_requests
       SET status = 'rejected',
           admin_note = NULLIF(trim(coalesce(p_note, '')), ''),
           updated_at = now()
     WHERE id = p_request_id;

    RETURN QUERY SELECT true, NULL::text, v_request.account_id, v_request.employee_user_uid, NULL::uuid, 'employee', NULL::boolean, true;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.superadmin_review_employee_seat_request(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.superadmin_review_employee_seat_request(uuid, boolean, text) TO PUBLIC;
