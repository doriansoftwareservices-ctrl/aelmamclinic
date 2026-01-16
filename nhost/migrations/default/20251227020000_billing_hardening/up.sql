-- Hardening billing/subscriptions: status constraints, audit logs, expiry, and RLS

BEGIN;

-- 1) Extend plans with grace period
ALTER TABLE public.subscription_plans
  ADD COLUMN IF NOT EXISTS grace_days integer NOT NULL DEFAULT 0;

-- 2) Status constraints (avoid invalid states)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'subscription_requests_status_chk'
  ) THEN
    ALTER TABLE public.subscription_requests
      ADD CONSTRAINT subscription_requests_status_chk
      CHECK (status IN ('pending','approved','rejected','cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'account_subscriptions_status_chk'
  ) THEN
    ALTER TABLE public.account_subscriptions
      ADD CONSTRAINT account_subscriptions_status_chk
      CHECK (status IN ('active','expired','cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'complaints_status_chk'
  ) THEN
    ALTER TABLE public.complaints
      ADD CONSTRAINT complaints_status_chk
      CHECK (status IN ('open','in_progress','resolved','closed'));
  END IF;
END$$;

-- 3) Indexes for common billing queries
CREATE INDEX IF NOT EXISTS subscription_requests_account_status_idx
  ON public.subscription_requests (account_id, status, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS subscription_requests_pending_uix
  ON public.subscription_requests (account_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS account_subscriptions_account_status_idx
  ON public.account_subscriptions (account_id, status, end_at);

CREATE INDEX IF NOT EXISTS subscription_payments_method_idx
  ON public.subscription_payments (payment_method_id);

-- 4) Plan features RLS (readable for all, writable by super admin)
ALTER TABLE public.plan_features ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS plan_features_select ON public.plan_features;
CREATE POLICY plan_features_select
ON public.plan_features
FOR SELECT TO PUBLIC
USING (true);

DROP POLICY IF EXISTS plan_features_manage ON public.plan_features;
CREATE POLICY plan_features_manage
ON public.plan_features
FOR ALL TO PUBLIC
USING (public.fn_is_super_admin() = true)
WITH CHECK (public.fn_is_super_admin() = true);

-- 5) Harden create_subscription_request (no duplicates, paid only)
CREATE OR REPLACE FUNCTION public.create_subscription_request(
  p_plan text,
  p_payment_method uuid,
  p_amount numeric,
  p_proof_url text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_plan text := lower(coalesce(p_plan, ''));
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT account_id INTO v_account
  FROM public.my_account_id()
  LIMIT 1;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'account not found';
  END IF;

  IF v_plan = '' OR v_plan = 'free' THEN
    RAISE EXCEPTION 'invalid plan';
  END IF;

  IF p_payment_method IS NULL THEN
    RAISE EXCEPTION 'payment_method is required';
  END IF;

  IF coalesce(p_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'amount must be > 0';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.subscription_plans WHERE code = v_plan AND is_active = true) THEN
    RAISE EXCEPTION 'plan not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.subscription_requests
    WHERE account_id = v_account AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'pending request exists';
  END IF;

  INSERT INTO public.subscription_requests(
    account_id,
    user_uid,
    plan_code,
    payment_method_id,
    amount,
    proof_url,
    status
  )
  VALUES (
    v_account,
    v_uid,
    v_plan,
    p_payment_method,
    p_amount,
    p_proof_url,
    'pending'
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_subscription_request(text, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(text, uuid, numeric, text) TO public;

-- 6) Admin: approve request + audit log
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

-- 7) Admin: reject request + audit log
DROP FUNCTION IF EXISTS public.admin_reject_subscription_request(uuid, text);
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

-- 8) Admin: change plan directly + audit log
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

-- 9) Scheduled expiry (uses grace_days)
CREATE OR REPLACE FUNCTION public.expire_account_subscriptions(
  p_dry_run boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_accounts uuid[];
  v_count integer := 0;
  r record;
BEGIN
  SELECT array_agg(s.account_id), count(*)
  INTO v_accounts, v_count
  FROM public.account_subscriptions s
  JOIN public.subscription_plans p ON p.code = s.plan_code
  WHERE s.status = 'active'
    AND s.end_at IS NOT NULL
    AND (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) <= now();

  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  IF p_dry_run THEN
    RETURN v_count;
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

  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_account_subscriptions(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.expire_account_subscriptions(boolean) TO public;

COMMIT;
