-- Align monthly trial usage detection with actual subscription history.
-- Historical approved requests may exist after older plan migrations, but the
-- one-time usage rule should be enforced by actual trial subscriptions.

CREATE OR REPLACE FUNCTION public.create_trial_plan_request(
  hasura_session json,
  p_clinic_name text DEFAULT NULL
)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_current_plan text := 'free';
  v_pending uuid;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  v_account := public.my_account_id();
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'account not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = v_account
      AND au.user_uid = v_uid
      AND lower(coalesce(au.role, '')) = 'owner'
      AND coalesce(au.disabled, false) = false
  ) THEN
    RAISE EXCEPTION 'forbidden (only owner can request trial activation)' USING ERRCODE = '42501';
  END IF;

  SELECT plan_code
    INTO v_current_plan
  FROM public.my_account_plan(hasura_session)
  LIMIT 1;

  v_current_plan := lower(coalesce(v_current_plan, 'free'));

  IF v_current_plan <> 'free' THEN
    RAISE EXCEPTION 'trial requires free plan';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_subscriptions s
    WHERE s.account_id = v_account
      AND s.plan_code = 'trial_month'
  ) THEN
    RAISE EXCEPTION 'trial already used';
  END IF;

  SELECT id
    INTO v_pending
  FROM public.subscription_requests
  WHERE account_id = v_account
    AND status = 'pending'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_pending IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.subscription_requests r
      WHERE r.id = v_pending
        AND r.plan_code = 'trial_month'
    ) THEN
      UPDATE public.subscription_requests
         SET amount = 0,
             payment_method_id = NULL,
             proof_url = NULL,
             reference_text = NULL,
             sender_name = NULL,
             clinic_name = nullif(trim(coalesce(p_clinic_name, '')), ''),
             updated_at = now()
       WHERE id = v_pending;
      RETURN QUERY SELECT v_pending::uuid AS id;
      RETURN;
    END IF;
    RAISE EXCEPTION 'pending request exists';
  END IF;

  INSERT INTO public.subscription_requests(
    account_id, user_uid, plan_code, payment_method_id, amount,
    proof_url, reference_text, sender_name, clinic_name, status
  )
  VALUES (
    v_account, v_uid, 'trial_month', NULL, 0,
    NULL, NULL, NULL, nullif(trim(coalesce(p_clinic_name, '')), ''), 'pending'
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  )
  VALUES (
    v_account,
    v_uid,
    'subscription_requests',
    'insert',
    v_id::text,
    jsonb_build_object('plan_code', 'trial_month', 'amount', 0, 'mode', 'trial')
  );

  RETURN QUERY SELECT v_id::uuid AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_trial_plan_request(json, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_trial_plan_request(json, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_approve_subscription_request(
  p_request uuid,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
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
    RETURN QUERY SELECT false, 'request not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF r.status <> 'pending' THEN
    RETURN QUERY SELECT false, 'request already processed', r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF lower(coalesce(r.plan_code, '')) = 'trial_month' AND EXISTS (
    SELECT 1
    FROM public.account_subscriptions s
    WHERE s.account_id = r.account_id
      AND s.plan_code = 'trial_month'
      AND coalesce(s.request_id, gen_random_uuid()) <> r.id
  ) THEN
    RETURN QUERY SELECT false, 'trial already used', r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT *
    INTO plan
  FROM public.subscription_plans
  WHERE code = r.plan_code
    AND is_active = true
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN QUERY SELECT false, 'plan not found', r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
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
  PERFORM public.ensure_account_owner_chat_code(r.account_id);

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  )
  VALUES (
    r.account_id, v_uid, 'account_subscriptions', 'plan.approve', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note)
  );

  RETURN QUERY SELECT true, NULL::text, r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_approve_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription_request(uuid, text) TO PUBLIC;

DROP FUNCTION IF EXISTS public.admin_set_account_plan(uuid, text, text);

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
  v_plan text := lower(coalesce(p_plan, 'free'));
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

  SELECT *
    INTO plan
  FROM public.subscription_plans
  WHERE code = v_plan
    AND is_active = true
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan not found');
  END IF;

  IF v_plan = 'trial_month' AND EXISTS (
    SELECT 1
    FROM public.account_subscriptions s
    WHERE s.account_id = p_account
      AND s.plan_code = 'trial_month'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'trial already used');
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

  RETURN jsonb_build_object('ok', true, 'account_id', p_account, 'plan', plan.code, 'note', p_note);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_account_plan(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_account_plan(uuid, text, text) TO PUBLIC;
