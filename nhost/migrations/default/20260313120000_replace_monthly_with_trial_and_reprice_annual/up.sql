BEGIN;

-- 1) Replace paid monthly catalog with a one-time trial month and reprice annual plans.
INSERT INTO public.subscription_plans(code, name, price_usd, duration_months, is_active)
VALUES
  ('trial_month', 'TRIAL_MONTH', 0, 1, true),
  ('year', 'YEAR', 199, 12, true),
  ('year_plus', 'YEAR_PLUS', 499, 12, true),
  ('year_pro', 'YEAR_PRO', 999, 12, true)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name,
      price_usd = EXCLUDED.price_usd,
      duration_months = EXCLUDED.duration_months,
      is_active = EXCLUDED.is_active,
      updated_at = now();

UPDATE public.subscription_plans
   SET is_active = false,
       updated_at = now()
 WHERE code IN ('month', 'month_plus', 'month_pro');

-- 2) Trial plan gets the same permissions/features as the current "month" plan.
DELETE FROM public.plan_features
 WHERE plan_code = 'trial_month';

INSERT INTO public.plan_features(plan_code, feature_key)
SELECT 'trial_month', pf.feature_key
FROM public.plan_features pf
WHERE pf.plan_code = 'month'
ON CONFLICT DO NOTHING;

-- 3) Normalize outstanding requests to the new commercial catalog.
UPDATE public.subscription_requests r
   SET amount = p.price_usd,
       updated_at = now()
  FROM public.subscription_plans p
 WHERE r.status = 'pending'
   AND r.plan_code = p.code
   AND r.plan_code IN ('year', 'year_plus', 'year_pro');

UPDATE public.subscription_requests
   SET status = 'rejected',
       note = trim(
         both ' '
         from concat_ws(
           ' | ',
           nullif(note, ''),
           'legacy monthly plan retired on 2026-03-13'
         )
       ),
       reviewed_at = coalesce(reviewed_at, now()),
       updated_at = now()
 WHERE status = 'pending'
   AND plan_code IN ('month', 'month_plus', 'month_pro');

-- 4) Owner-only paid annual requests. Trial requests use a dedicated mutation.
CREATE OR REPLACE FUNCTION public.create_subscription_request(
  hasura_session json,
  p_plan text,
  p_payment_method uuid,
  p_proof_url text DEFAULT NULL,
  p_reference_text text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
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
  v_plan text := lower(coalesce(p_plan, ''));
  v_price numeric(10,2);
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
    RAISE EXCEPTION 'forbidden (only owner can request a plan)' USING ERRCODE = '42501';
  END IF;

  IF v_plan = '' OR v_plan = 'free' OR v_plan = 'trial_month' THEN
    RAISE EXCEPTION 'invalid plan';
  END IF;

  IF v_plan NOT IN ('year', 'year_plus', 'year_pro') THEN
    RAISE EXCEPTION 'plan not available';
  END IF;

  IF p_payment_method IS NULL THEN
    RAISE EXCEPTION 'payment_method is required';
  END IF;

  SELECT sp.price_usd INTO v_price
  FROM public.subscription_plans sp
  WHERE sp.code = v_plan
    AND sp.is_active = true
  LIMIT 1;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'plan not found';
  END IF;

  SELECT id INTO v_pending
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
      RAISE EXCEPTION 'pending request exists';
    END IF;

    UPDATE public.subscription_requests
       SET plan_code = v_plan,
           payment_method_id = p_payment_method,
           amount = v_price,
           proof_url = nullif(trim(coalesce(p_proof_url, '')), ''),
           reference_text = nullif(trim(coalesce(p_reference_text, '')), ''),
           sender_name = nullif(trim(coalesce(p_sender_name, '')), ''),
           clinic_name = nullif(trim(coalesce(p_clinic_name, '')), ''),
           updated_at = now()
     WHERE id = v_pending;

    RETURN QUERY SELECT v_pending::uuid AS id;
    RETURN;
  END IF;

  INSERT INTO public.subscription_requests(
    account_id,
    user_uid,
    plan_code,
    payment_method_id,
    amount,
    proof_url,
    reference_text,
    sender_name,
    clinic_name,
    status
  )
  VALUES (
    v_account,
    v_uid,
    v_plan,
    p_payment_method,
    v_price,
    nullif(trim(coalesce(p_proof_url, '')), ''),
    nullif(trim(coalesce(p_reference_text, '')), ''),
    nullif(trim(coalesce(p_sender_name, '')), ''),
    nullif(trim(coalesce(p_clinic_name, '')), ''),
    'pending'
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs(
    account_id,
    actor_uid,
    actor_email,
    table_name,
    op,
    row_pk,
    after_row
  )
  VALUES (
    v_account,
    v_uid,
    coalesce(public.request_email_text(), ''),
    'subscription_requests',
    'insert',
    v_id::text,
    jsonb_build_object('plan_code', v_plan, 'amount', v_price)
  );

  RETURN QUERY SELECT v_id::uuid AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text, text) TO PUBLIC;

-- 5) Dedicated one-time trial request.
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
    FROM public.subscription_requests r
    WHERE r.account_id = v_account
      AND r.plan_code = 'trial_month'
      AND r.status = 'approved'
  ) OR EXISTS (
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
    account_id,
    user_uid,
    plan_code,
    payment_method_id,
    amount,
    proof_url,
    reference_text,
    sender_name,
    clinic_name,
    status
  )
  VALUES (
    v_account,
    v_uid,
    'trial_month',
    NULL,
    0,
    NULL,
    NULL,
    NULL,
    nullif(trim(coalesce(p_clinic_name, '')), ''),
    'pending'
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs(
    account_id,
    actor_uid,
    actor_email,
    table_name,
    op,
    row_pk,
    after_row
  )
  VALUES (
    v_account,
    v_uid,
    coalesce(public.request_email_text(), ''),
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

-- 6) Approval path: reject legacy inactive plans and enforce one-time trial usage.
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

  IF lower(coalesce(r.plan_code, '')) = 'trial_month' AND (
    EXISTS (
      SELECT 1
      FROM public.subscription_requests prev
      WHERE prev.account_id = r.account_id
        AND prev.plan_code = 'trial_month'
        AND prev.status = 'approved'
        AND prev.id <> r.id
    ) OR EXISTS (
      SELECT 1
      FROM public.account_subscriptions s
      WHERE s.account_id = r.account_id
        AND s.plan_code = 'trial_month'
        AND coalesce(s.request_id, gen_random_uuid()) <> r.id
    )
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

-- 7) Manual super-admin assignment must respect the active catalog and one-time trial rule.
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

  IF v_plan = 'trial_month' AND (
    EXISTS (
      SELECT 1
      FROM public.subscription_requests r
      WHERE r.account_id = p_account
        AND r.plan_code = 'trial_month'
        AND r.status = 'approved'
    ) OR EXISTS (
      SELECT 1
      FROM public.account_subscriptions s
      WHERE s.account_id = p_account
        AND s.plan_code = 'trial_month'
    )
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

-- 8) Revenue views should be based on actual paid payments only.
CREATE OR REPLACE VIEW public.v_admin_mrr_by_month AS
SELECT
  date_trunc('month', received_at) AS month,
  SUM(COALESCE(amount, 0))::numeric AS mrr
FROM public.subscription_payments
WHERE plan_code IN ('year', 'year_plus', 'year_pro')
GROUP BY 1
ORDER BY 1 DESC;

CREATE OR REPLACE VIEW public.v_admin_arr_by_month AS
SELECT
  month,
  (mrr * 12)::numeric AS arr
FROM public.v_admin_mrr_by_month;

CREATE OR REPLACE VIEW public.v_admin_payment_stats_by_plan AS
SELECT
  x.plan_code,
  COALESCE(SUM(x.amount), 0)::numeric AS total_amount,
  COUNT(*)::bigint AS payments_count
FROM (
  SELECT plan_code, amount
  FROM public.subscription_payments
  WHERE plan_code IN ('year', 'year_plus', 'year_pro')
  UNION ALL
  SELECT 'extra_seat'::text AS plan_code, amount
  FROM public.employee_seat_payments
) x
GROUP BY x.plan_code;

CREATE OR REPLACE VIEW public.v_admin_dashboard_payments AS
SELECT
  p.id AS payment_id,
  p.received_at,
  p.account_id,
  a.name AS account_name,
  p.plan_code,
  sp.name AS plan_name,
  p.amount AS amount_usd,
  pm.name AS payment_method,
  p.request_id,
  p.created_by,
  coalesce(au.email, sa.email, '') AS created_by_email
FROM public.subscription_payments p
JOIN public.accounts a ON a.id = p.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = p.plan_code
LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
LEFT JOIN public.account_users au ON au.account_id = p.account_id AND au.user_uid = p.created_by
LEFT JOIN public.super_admins sa ON sa.user_uid = p.created_by
WHERE p.plan_code IN ('year', 'year_plus', 'year_pro');

CREATE OR REPLACE VIEW public.v_admin_dashboard_revenue_monthly AS
SELECT
  date_trunc('month', received_at) AS month,
  count(*) AS payments_count,
  round(sum(amount)::numeric, 2) AS total_amount_usd,
  round(avg(amount)::numeric, 2) AS avg_payment_usd
FROM public.subscription_payments
WHERE plan_code IN ('year', 'year_plus', 'year_pro')
GROUP BY 1;

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
    SELECT payment_method_id, amount
    FROM public.subscription_payments
    WHERE plan_code IN ('year', 'year_plus', 'year_pro')
    UNION ALL
    SELECT payment_method_id, amount
    FROM public.employee_seat_payments
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
    SELECT plan_code, amount
    FROM public.subscription_payments
    WHERE plan_code IN ('year', 'year_plus', 'year_pro')
    UNION ALL
    SELECT 'extra_seat'::text AS plan_code, amount
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
    SELECT amount, received_at
    FROM public.subscription_payments
    WHERE plan_code IN ('year', 'year_plus', 'year_pro')
    UNION ALL
    SELECT amount, received_at
    FROM public.employee_seat_payments
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
    SELECT amount, received_at
    FROM public.subscription_payments
    WHERE plan_code IN ('year', 'year_plus', 'year_pro')
    UNION ALL
    SELECT amount, received_at
    FROM public.employee_seat_payments
  ) x
  GROUP BY month
  ORDER BY month DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_month() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_month() TO public;

COMMIT;
