-- Normalize RPC return types so Hasura can track them.

BEGIN;

CREATE OR REPLACE VIEW public.v_uuid_result AS
SELECT NULL::uuid AS id
WHERE false;

-- Drop overloads that cause Hasura tracking errors.
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, numeric, text, text, text);
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.self_create_account(text);

-- self_create_account now returns a table-backed row.
CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_name text := coalesce(nullif(trim(p_clinic_name), ''), '');
  v_account uuid;
  v_email text;
  exists_member boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'clinic_name is required';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.user_uid = v_uid
  ) INTO exists_member;

  IF exists_member THEN
    RAISE EXCEPTION 'already linked to an account' USING ERRCODE = '23505';
  END IF;

  SELECT lower(coalesce(email, ''))
    INTO v_email
    FROM auth.users
   WHERE id = v_uid
   ORDER BY created_at DESC
   LIMIT 1;

  INSERT INTO public.accounts(name, frozen)
  VALUES (v_name, false)
  RETURNING id INTO v_account;

  INSERT INTO public.account_users(account_id, user_uid, role, disabled, email)
  VALUES (v_account, v_uid, 'owner', false, nullif(v_email, ''));

  INSERT INTO public.profiles(id, account_id, role, email, disabled, created_at)
  VALUES (
    v_uid,
    v_account,
    'owner',
    nullif(v_email, ''),
    false,
    now()
  )
  ON CONFLICT (id) DO UPDATE
      SET account_id = EXCLUDED.account_id,
          role = EXCLUDED.role,
          email = COALESCE(EXCLUDED.email, public.profiles.email),
          disabled = false;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', 'owner',
           'account_id', v_account::text
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', 'owner',
           'account_id', v_account::text
         )
   WHERE id = v_uid;

  INSERT INTO public.account_feature_permissions(account_id, user_uid, allowed_features)
  VALUES (v_account, v_uid, public.plan_allowed_features('free'))
  ON CONFLICT (account_id, user_uid) DO NOTHING;

  INSERT INTO public.account_subscriptions(account_id, plan_code, status, start_at, end_at, approved_at)
  VALUES (v_account, 'free', 'active', now(), NULL, now());

  PERFORM public.apply_plan_permissions(v_account, 'free');

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    v_account, v_uid, 'accounts', 'account.bootstrap', v_account::text,
    jsonb_build_object('plan', 'free', 'owner', v_uid::text)
  );

  RETURN QUERY SELECT v_account AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.self_create_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO public;

-- create_subscription_request now returns a table-backed row (request id).
CREATE OR REPLACE FUNCTION public.create_subscription_request(
  p_plan text,
  p_payment_method uuid,
  p_proof_url text DEFAULT NULL,
  p_reference_text text DEFAULT NULL,
  p_sender_name text DEFAULT NULL
)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_plan text := lower(coalesce(p_plan, ''));
  v_price numeric;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT account_id
  INTO v_account
  FROM public.account_users
  WHERE user_uid = v_uid
    AND coalesce(disabled, false) = false
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'no account' USING ERRCODE = '23503';
  END IF;

  SELECT price_usd
    INTO v_price
    FROM public.subscription_plans
   WHERE code = v_plan
     AND is_active = true
   LIMIT 1;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'invalid plan' USING ERRCODE = '22023';
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
    status
  ) VALUES (
    v_account,
    v_uid,
    v_plan,
    p_payment_method,
    v_price,
    p_proof_url,
    p_reference_text,
    p_sender_name,
    'pending'
  )
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_subscription_request(text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(text, uuid, text, text, text) TO public;

-- Admin approve/reject now return table-backed results.
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

  SELECT * INTO plan
  FROM public.subscription_plans
  WHERE code = r.plan_code
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

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    r.account_id, v_uid, 'account_subscriptions', 'plan.approve', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note)
  );

  RETURN QUERY SELECT true, NULL::text, r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_approve_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription_request(uuid, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_reject_subscription_request(
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

  UPDATE public.subscription_requests
     SET status = 'rejected',
         note = p_note,
         reviewed_by = v_uid,
         reviewed_at = now()
   WHERE id = r.id;

  RETURN QUERY SELECT true, NULL::text, r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_reject_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reject_subscription_request(uuid, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_set_account_plan(
  p_account uuid,
  p_plan text,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
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

  SELECT * INTO plan
  FROM public.subscription_plans
  WHERE code = lower(p_plan)
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN QUERY SELECT false, 'plan not found', p_account, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
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

  RETURN QUERY SELECT true, NULL::text, p_account, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_account_plan(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_account_plan(uuid, text, text) TO public;

CREATE OR REPLACE FUNCTION public.expire_account_subscriptions(
  p_dry_run boolean DEFAULT false
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  r record;
BEGIN
  SELECT count(*)
    INTO v_count
  FROM public.account_subscriptions s
  JOIN public.subscription_plans p ON p.code = s.plan_code
  WHERE s.status = 'active'
    AND s.end_at IS NOT NULL
    AND (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) <= now();

  IF v_count = 0 THEN
    RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_dry_run THEN
    RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  FOR r IN
    SELECT s.account_id, s.plan_code
    FROM public.account_subscriptions s
    JOIN public.subscription_plans p ON p.code = s.plan_code
    WHERE s.status = 'active'
      AND s.end_at IS NOT NULL
      AND (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) <= now()
  LOOP
    UPDATE public.account_subscriptions
       SET status = 'expired',
           updated_at = now()
     WHERE account_id = r.account_id
       AND status = 'active';

    INSERT INTO public.account_subscriptions(
      account_id, plan_code, status, start_at, approved_at
    )
    VALUES (r.account_id, 'free', 'active', now(), now());

    PERFORM public.apply_plan_permissions(r.account_id, 'free');

    INSERT INTO public.audit_logs(
      account_id, actor_uid, table_name, op, row_pk, after_row
    ) VALUES (
      r.account_id, NULL, 'account_subscriptions', 'plan.expire', r.plan_code,
      jsonb_build_object('from', r.plan_code, 'to', 'free')
    );
  END LOOP;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_account_subscriptions(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.expire_account_subscriptions(boolean) TO public;

-- Ensure admin payment stats return table types for Hasura tracking.
DROP FUNCTION IF EXISTS public.admin_payment_stats();
DROP FUNCTION IF EXISTS public.admin_payment_stats_by_plan();
DROP FUNCTION IF EXISTS public.admin_payment_stats_by_day();
DROP FUNCTION IF EXISTS public.admin_payment_stats_by_month();

CREATE OR REPLACE FUNCTION public.admin_payment_stats()
RETURNS TABLE (
  payment_method_id uuid,
  payment_method_name text,
  total_amount numeric,
  payments_count bigint
)
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
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  LEFT JOIN public.payment_methods pm
    ON pm.id = sp.payment_method_id
  GROUP BY pm.id, pm.name
  ORDER BY total_amount DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_plan()
RETURNS TABLE (
  plan_code text,
  total_amount numeric,
  payments_count bigint
)
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
    sp.plan_code,
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  GROUP BY sp.plan_code
  ORDER BY total_amount DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_plan() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_day()
RETURNS TABLE (
  day date,
  total_amount numeric,
  payments_count bigint
)
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
    date_trunc('day', sp.received_at)::date AS day,
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  GROUP BY day
  ORDER BY day DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_day() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_day() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_month()
RETURNS TABLE (
  month date,
  total_amount numeric,
  payments_count bigint
)
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
    date_trunc('month', sp.received_at)::date AS month,
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  GROUP BY month
  ORDER BY month DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_month() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_month() TO public;

COMMIT;
