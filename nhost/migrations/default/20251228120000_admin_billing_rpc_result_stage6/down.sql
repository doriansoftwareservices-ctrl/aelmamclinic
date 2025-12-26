-- Restore admin billing RPCs to JSONB returns.

CREATE OR REPLACE FUNCTION public.admin_approve_subscription_request(
  p_request uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  r record;
  plan record;
  v_start timestamptz := now();
  v_end timestamptz := NULL;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO r
  FROM public.subscription_requests
  WHERE id = p_request
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request not found');
  END IF;

  IF r.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request already processed');
  END IF;

  SELECT * INTO plan
  FROM public.subscription_plans
  WHERE code = r.plan_code
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan not found');
  END IF;

  IF coalesce(plan.duration_months, 0) > 0 THEN
    v_end := v_start + (plan.duration_months::text || ' months')::interval;
  END IF;

  UPDATE public.subscription_requests
     SET status = 'approved',
         note = p_note,
         reviewed_by = v_uid,
         reviewed_at = now()
   WHERE id = r.id;

  UPDATE public.account_subscriptions
     SET status = 'expired',
         updated_at = now()
   WHERE account_id = r.account_id
     AND status = 'active';

  INSERT INTO public.account_subscriptions(
    account_id, plan_code, status, start_at, end_at, approved_by, approved_at, request_id
  )
  VALUES (
    r.account_id, plan.code, 'active', v_start, v_end, v_uid, now(), r.id
  );

  IF coalesce(r.amount, 0) > 0 THEN
    INSERT INTO public.subscription_payments(
      account_id, request_id, payment_method_id, plan_code, amount, created_by
    )
    VALUES (r.account_id, r.id, r.payment_method_id, r.plan_code, r.amount, v_uid);
  END IF;

  PERFORM public.apply_plan_permissions(r.account_id, r.plan_code);

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    r.account_id, v_uid, 'account_subscriptions', 'plan.approve', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note)
  );

  RETURN jsonb_build_object('ok', true, 'account_id', r.account_id, 'plan', r.plan_code);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_approve_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription_request(uuid, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_reject_subscription_request(
  p_request uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  r record;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO r
  FROM public.subscription_requests
  WHERE id = p_request
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request not found');
  END IF;

  IF r.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request already processed');
  END IF;

  UPDATE public.subscription_requests
     SET status = 'rejected',
         note = p_note,
         reviewed_by = v_uid,
         reviewed_at = now()
   WHERE id = r.id;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    r.account_id, v_uid, 'subscription_requests', 'plan.reject', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note)
  );

  RETURN jsonb_build_object('ok', true, 'account_id', r.account_id, 'plan', r.plan_code);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_reject_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reject_subscription_request(uuid, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_set_account_plan(
  p_account uuid,
  p_plan text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  plan record;
  v_start timestamptz := now();
  v_end timestamptz := NULL;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_account IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  SELECT * INTO plan
  FROM public.subscription_plans
  WHERE code = lower(coalesce(p_plan, 'free'))
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan not found');
  END IF;

  IF coalesce(plan.duration_months, 0) > 0 THEN
    v_end := v_start + (plan.duration_months::text || ' months')::interval;
  END IF;

  UPDATE public.account_subscriptions
     SET status = 'expired',
         updated_at = now()
   WHERE account_id = p_account
     AND status = 'active';

  INSERT INTO public.account_subscriptions(
    account_id, plan_code, status, start_at, end_at, approved_by, approved_at
  )
  VALUES (p_account, plan.code, 'active', v_start, v_end, v_uid, now());

  PERFORM public.apply_plan_permissions(p_account, plan.code);

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    p_account, v_uid, 'account_subscriptions', 'plan.set', plan.code,
    jsonb_build_object('plan', plan.code, 'note', p_note)
  );

  RETURN jsonb_build_object('ok', true, 'account_id', p_account, 'plan', plan.code, 'note', p_note);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_account_plan(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_account_plan(uuid, text, text) TO public;
