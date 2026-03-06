-- Ensure chat_code is assigned when extra seat requests are approved.

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
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
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

    -- Ensure chat code exists after approval
    PERFORM public.ensure_account_user_chat_code(
      v_request.account_id,
      v_request.employee_user_uid
    );

    INSERT INTO public.employee_seat_payments(
      account_id, request_id, payment_method_id, amount, received_at, created_by, seat_kind
    ) VALUES (
      v_request.account_id,
      v_request.id,
      v_request.payment_method_id,
      COALESCE(v_request.price_usd, 0),
      now(),
      v_uid,
      COALESCE(v_request.seat_kind, 'extra')
    ) ON CONFLICT ON CONSTRAINT employee_seat_payments_request_uq DO NOTHING;

    INSERT INTO public.audit_logs(
      account_id, actor_uid, table_name, op, row_pk, after_row
    ) VALUES (
      v_request.account_id, v_uid, 'employee_seat_requests', 'seat.approve', v_request.id::text,
      jsonb_build_object(
        'employee_uid', v_request.employee_user_uid,
        'amount', v_request.price_usd,
        'payment_method_id', v_request.payment_method_id,
        'seat_kind', v_request.seat_kind,
        'note', NULLIF(trim(coalesce(p_note, '')), '')
      )
    );

    RETURN QUERY SELECT true, NULL::text, v_request.account_id, v_request.employee_user_uid, NULL::uuid, 'employee', NULL::boolean, false;
  ELSE
    UPDATE public.employee_seat_requests
       SET status = 'rejected',
           admin_note = NULLIF(trim(coalesce(p_note, '')), ''),
           updated_at = now()
     WHERE id = p_request_id;

    INSERT INTO public.audit_logs(
      account_id, actor_uid, table_name, op, row_pk, after_row
    ) VALUES (
      v_request.account_id, v_uid, 'employee_seat_requests', 'seat.reject', v_request.id::text,
      jsonb_build_object(
        'employee_uid', v_request.employee_user_uid,
        'seat_kind', v_request.seat_kind,
        'note', NULLIF(trim(coalesce(p_note, '')), '')
      )
    );

    RETURN QUERY SELECT true, NULL::text, v_request.account_id, v_request.employee_user_uid, NULL::uuid, 'employee', NULL::boolean, true;
  END IF;
END;
$$;

-- Backfill missing chat_code for active employees/admins
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT au.account_id, au.user_uid
      FROM public.account_users au
     WHERE (au.chat_code IS NULL OR btrim(au.chat_code) = '')
       AND lower(coalesce(au.role, '')) IN ('employee', 'admin')
       AND coalesce(au.disabled, false) = false
  LOOP
    PERFORM public.ensure_account_user_chat_code(r.account_id, r.user_uid);
  END LOOP;
END$$;
