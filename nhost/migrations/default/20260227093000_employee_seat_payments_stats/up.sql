BEGIN;

CREATE TABLE IF NOT EXISTS public.employee_seat_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  request_id uuid REFERENCES public.employee_seat_requests(id) ON DELETE SET NULL,
  payment_method_id uuid REFERENCES public.payment_methods(id),
  amount numeric(10,2) NOT NULL DEFAULT 0,
  received_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  seat_kind text NOT NULL DEFAULT 'extra'
);

CREATE UNIQUE INDEX IF NOT EXISTS employee_seat_payments_request_uix
  ON public.employee_seat_payments(request_id)
  WHERE request_id IS NOT NULL;

-- Update owner submit to audit
CREATE OR REPLACE FUNCTION public.owner_submit_employee_seat_payment(
  hasura_session json,
  p_request_id uuid,
  p_payment_method_id uuid DEFAULT NULL,
  p_receipt_file_id text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id', '')::uuid;
  v_account uuid;
  v_role text;
  v_request record;
  v_receipt text := nullif(trim(coalesce(p_receipt_file_id, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT au.account_id, au.role
    INTO v_account, v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND coalesce(au.disabled, false) = false
   ORDER BY au.created_at DESC
   LIMIT 1;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF lower(coalesce(v_role, '')) <> 'owner' THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_receipt IS NULL THEN
    RETURN QUERY SELECT false, 'receipt is required', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT *
    INTO v_request
    FROM public.employee_seat_requests r
   WHERE r.id = p_request_id
   LIMIT 1;

  IF v_request.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_request.account_id <> v_account OR v_request.requested_by_uid <> v_uid THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_request.status IN ('submitted', 'approved') THEN
    RETURN QUERY SELECT false, 'request already submitted', v_account, v_request.employee_user_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE public.employee_seat_requests
     SET status = 'submitted',
         payment_method_id = p_payment_method_id,
         receipt_file_id = v_receipt,
         updated_at = now()
   WHERE id = p_request_id;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    v_account, v_uid, 'employee_seat_requests', 'seat.submit', v_request.id::text,
    jsonb_build_object(
      'employee_uid', v_request.employee_user_uid,
      'payment_method_id', p_payment_method_id,
      'receipt_file_id', v_receipt
    )
  );

  RETURN QUERY SELECT true, NULL::text, v_account, v_request.employee_user_uid, v_uid, 'employee', NULL::boolean, true;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_submit_employee_seat_payment(json, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_submit_employee_seat_payment(json, uuid, uuid, text) TO PUBLIC;

-- Superadmin review: approve + insert payment entry + audit
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
    ) ON CONFLICT (request_id) DO NOTHING;

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
REVOKE ALL ON FUNCTION public.superadmin_review_employee_seat_request(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.superadmin_review_employee_seat_request(uuid, boolean, text) TO PUBLIC;

-- Extend admin payment stats to include extra seat payments
CREATE OR REPLACE FUNCTION public.admin_payment_stats()
RETURNS SETOF public.v_payment_stats
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pm.id AS payment_method_id,
    pm.name AS payment_method_name,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT payment_method_id, amount FROM public.subscription_payments
    UNION ALL
    SELECT payment_method_id, amount FROM public.employee_seat_payments
  ) x
  LEFT JOIN public.payment_methods pm
    ON pm.id = x.payment_method_id
  GROUP BY pm.id, pm.name
  ORDER BY total_amount DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_plan()
RETURNS SETOF public.v_payment_stats_by_plan
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    x.plan_code,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT plan_code, amount, received_at FROM public.subscription_payments
    UNION ALL
    SELECT 'extra_seat'::text AS plan_code, amount, received_at
      FROM public.employee_seat_payments
  ) x
  GROUP BY x.plan_code
  ORDER BY total_amount DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_plan() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_day()
RETURNS SETOF public.v_payment_stats_by_day
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    date_trunc('day', x.received_at)::date AS day,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT amount, received_at FROM public.subscription_payments
    UNION ALL
    SELECT amount, received_at FROM public.employee_seat_payments
  ) x
  GROUP BY day
  ORDER BY day DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_day() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_day() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_month()
RETURNS SETOF public.v_payment_stats_by_month
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    date_trunc('month', x.received_at)::date AS month,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT amount, received_at FROM public.subscription_payments
    UNION ALL
    SELECT amount, received_at FROM public.employee_seat_payments
  ) x
  GROUP BY month
  ORDER BY month DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_month() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_month() TO public;

COMMIT;
