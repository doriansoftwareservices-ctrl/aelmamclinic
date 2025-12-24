-- Billing, plans, subscription requests, payment methods, and complaints.

BEGIN;

-- 1) Plans catalog
CREATE TABLE IF NOT EXISTS public.subscription_plans (
  code            text PRIMARY KEY,
  name            text NOT NULL,
  price_usd       numeric(10,2) NOT NULL DEFAULT 0,
  duration_months integer NOT NULL DEFAULT 0,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.subscription_plans(code, name, price_usd, duration_months, is_active)
VALUES
  ('free', 'FREE', 0, 0, true),
  ('month', 'MONTH', 30, 1, true),
  ('year', 'YEAR', 350, 12, true)
ON CONFLICT (code) DO NOTHING;

-- 2) Payment methods
CREATE TABLE IF NOT EXISTS public.payment_methods (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  logo_url    text,
  bank_account text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- 3) Subscription requests from users
CREATE TABLE IF NOT EXISTS public.subscription_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        uuid NOT NULL,
  user_uid          uuid NOT NULL,
  plan_code         text NOT NULL REFERENCES public.subscription_plans(code),
  payment_method_id uuid REFERENCES public.payment_methods(id),
  amount            numeric(10,2),
  proof_url         text,
  status            text NOT NULL DEFAULT 'pending',
  note              text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  reviewed_by       uuid,
  reviewed_at       timestamptz
);

-- 4) Active subscriptions (one active per account)
CREATE TABLE IF NOT EXISTS public.account_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid NOT NULL,
  plan_code    text NOT NULL REFERENCES public.subscription_plans(code),
  status       text NOT NULL DEFAULT 'active',
  start_at     timestamptz,
  end_at       timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  approved_by  uuid,
  approved_at  timestamptz,
  request_id   uuid REFERENCES public.subscription_requests(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS account_subscriptions_active_uix
  ON public.account_subscriptions(account_id)
  WHERE status = 'active';

-- 5) Subscription payments (for statistics)
CREATE TABLE IF NOT EXISTS public.subscription_payments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        uuid NOT NULL,
  request_id        uuid REFERENCES public.subscription_requests(id) ON DELETE SET NULL,
  payment_method_id uuid REFERENCES public.payment_methods(id),
  plan_code         text REFERENCES public.subscription_plans(code),
  amount            numeric(10,2) NOT NULL DEFAULT 0,
  received_at       timestamptz NOT NULL DEFAULT now(),
  created_by        uuid
);

-- 6) Complaints / incidents
CREATE TABLE IF NOT EXISTS public.complaints (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL,
  user_uid    uuid NOT NULL,
  subject     text,
  message     text NOT NULL,
  status      text NOT NULL DEFAULT 'open',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  handled_by  uuid,
  handled_at  timestamptz
);

-- 7) Updated_at triggers (reuse generic pattern)
CREATE OR REPLACE FUNCTION public.tg_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS payment_methods_touch ON public.payment_methods;
CREATE TRIGGER payment_methods_touch
BEFORE UPDATE ON public.payment_methods
FOR EACH ROW
EXECUTE FUNCTION public.tg_touch_updated_at();

DROP TRIGGER IF EXISTS subscription_requests_touch ON public.subscription_requests;
CREATE TRIGGER subscription_requests_touch
BEFORE UPDATE ON public.subscription_requests
FOR EACH ROW
EXECUTE FUNCTION public.tg_touch_updated_at();

DROP TRIGGER IF EXISTS account_subscriptions_touch ON public.account_subscriptions;
CREATE TRIGGER account_subscriptions_touch
BEFORE UPDATE ON public.account_subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.tg_touch_updated_at();

DROP TRIGGER IF EXISTS complaints_touch ON public.complaints;
CREATE TRIGGER complaints_touch
BEFORE UPDATE ON public.complaints
FOR EACH ROW
EXECUTE FUNCTION public.tg_touch_updated_at();

-- 8) RLS
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.complaints ENABLE ROW LEVEL SECURITY;

-- Payment methods: readable by all authenticated users, writable by super admin only
DROP POLICY IF EXISTS payment_methods_select ON public.payment_methods;
CREATE POLICY payment_methods_select
ON public.payment_methods
FOR SELECT TO PUBLIC
USING (is_active = true OR public.fn_is_super_admin() = true);

DROP POLICY IF EXISTS payment_methods_manage ON public.payment_methods;
CREATE POLICY payment_methods_manage
ON public.payment_methods
FOR ALL TO PUBLIC
USING (public.fn_is_super_admin() = true)
WITH CHECK (public.fn_is_super_admin() = true);

-- Subscription requests: members can view/insert their account; super admin full
DROP POLICY IF EXISTS subscription_requests_select ON public.subscription_requests;
CREATE POLICY subscription_requests_select
ON public.subscription_requests
FOR SELECT TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR public.fn_is_account_member(subscription_requests.account_id)
);

DROP POLICY IF EXISTS subscription_requests_insert ON public.subscription_requests;
CREATE POLICY subscription_requests_insert
ON public.subscription_requests
FOR INSERT TO PUBLIC
WITH CHECK (
  public.fn_is_account_member(subscription_requests.account_id)
  AND subscription_requests.user_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS subscription_requests_update ON public.subscription_requests;
CREATE POLICY subscription_requests_update
ON public.subscription_requests
FOR UPDATE TO PUBLIC
USING (public.fn_is_super_admin() = true)
WITH CHECK (public.fn_is_super_admin() = true);

-- Account subscriptions: readable by members; writable by super admin
DROP POLICY IF EXISTS account_subscriptions_select ON public.account_subscriptions;
CREATE POLICY account_subscriptions_select
ON public.account_subscriptions
FOR SELECT TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR public.fn_is_account_member(account_subscriptions.account_id)
);

DROP POLICY IF EXISTS account_subscriptions_manage ON public.account_subscriptions;
CREATE POLICY account_subscriptions_manage
ON public.account_subscriptions
FOR ALL TO PUBLIC
USING (public.fn_is_super_admin() = true)
WITH CHECK (public.fn_is_super_admin() = true);

-- Payments: super admin only
DROP POLICY IF EXISTS subscription_payments_manage ON public.subscription_payments;
CREATE POLICY subscription_payments_manage
ON public.subscription_payments
FOR ALL TO PUBLIC
USING (public.fn_is_super_admin() = true)
WITH CHECK (public.fn_is_super_admin() = true);

-- Complaints: members can read/insert; super admin can update
DROP POLICY IF EXISTS complaints_select ON public.complaints;
CREATE POLICY complaints_select
ON public.complaints
FOR SELECT TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR public.fn_is_account_member(complaints.account_id)
);

DROP POLICY IF EXISTS complaints_insert ON public.complaints;
CREATE POLICY complaints_insert
ON public.complaints
FOR INSERT TO PUBLIC
WITH CHECK (
  public.fn_is_account_member(complaints.account_id)
  AND complaints.user_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS complaints_update ON public.complaints;
CREATE POLICY complaints_update
ON public.complaints
FOR UPDATE TO PUBLIC
USING (public.fn_is_super_admin() = true)
WITH CHECK (public.fn_is_super_admin() = true);

-- 9) View + RPC: my_account_plan
CREATE OR REPLACE VIEW public.v_my_account_plan AS
SELECT NULL::text AS plan_code
WHERE false;

DROP FUNCTION IF EXISTS public.my_account_plan();
CREATE OR REPLACE FUNCTION public.my_account_plan()
RETURNS SETOF public.v_my_account_plan
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH acc AS (
    SELECT account_id
    FROM public.my_account_id()
    LIMIT 1
  ),
  active_sub AS (
    SELECT s.plan_code
    FROM public.account_subscriptions s
    JOIN acc ON acc.account_id = s.account_id
    WHERE s.status = 'active'
      AND (s.end_at IS NULL OR s.end_at > now())
    ORDER BY s.created_at DESC
    LIMIT 1
  )
  SELECT COALESCE((SELECT plan_code FROM active_sub), 'free') AS plan_code;
$$;
REVOKE ALL ON FUNCTION public.my_account_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_plan() TO PUBLIC;

-- 10) View-backed RPC for payment methods
CREATE OR REPLACE VIEW public.v_payment_methods AS
SELECT
  NULL::uuid AS id,
  NULL::text AS name,
  NULL::text AS logo_url,
  NULL::text AS bank_account,
  NULL::boolean AS is_active
WHERE false;

DROP FUNCTION IF EXISTS public.list_payment_methods();
CREATE OR REPLACE FUNCTION public.list_payment_methods()
RETURNS SETOF public.v_payment_methods
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id, name, logo_url, bank_account, is_active
  FROM public.payment_methods
  WHERE is_active = true
  ORDER BY created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.list_payment_methods() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_payment_methods() TO PUBLIC;

-- 10.1) Payment stats view + RPC (super admin)
CREATE OR REPLACE VIEW public.v_payment_stats AS
SELECT
  NULL::uuid AS payment_method_id,
  NULL::text AS payment_method_name,
  NULL::numeric AS total_amount,
  NULL::bigint AS payments_count
WHERE false;

DROP FUNCTION IF EXISTS public.admin_payment_stats();
CREATE OR REPLACE FUNCTION public.admin_payment_stats()
RETURNS SETOF public.v_payment_stats
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats() TO public;

-- 11) Apply plan permissions (free vs paid)
CREATE OR REPLACE FUNCTION public.apply_plan_permissions(
  p_account uuid,
  p_plan text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  free_features text[] := ARRAY['dashboard','patients.new','patients.list','employees'];
BEGIN
  IF p_account IS NULL THEN
    RETURN;
  END IF;

  IF coalesce(p_plan, 'free') = 'free' THEN
    UPDATE public.account_feature_permissions
       SET allowed_features = free_features,
           can_create = true,
           can_update = true,
           can_delete = true
     WHERE account_id = p_account;
  ELSE
    UPDATE public.account_feature_permissions
       SET allowed_features = ARRAY[]::text[],
           can_create = true,
           can_update = true,
           can_delete = true
     WHERE account_id = p_account;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO public;

-- 12) User flow: create account for current user (owner, free plan)
CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_name text := coalesce(nullif(trim(p_clinic_name), ''), '');
  v_account uuid;
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
      AND coalesce(au.disabled, false) = false
  ) INTO exists_member;

  IF exists_member THEN
    RAISE EXCEPTION 'already linked to an account' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.accounts(name, frozen)
  VALUES (v_name, false)
  RETURNING id INTO v_account;

  PERFORM public.admin_attach_employee(v_account, v_uid, 'owner');

  UPDATE public.account_users
     SET role = 'owner',
         disabled = false,
         updated_at = now()
   WHERE account_id = v_account
     AND user_uid = v_uid;

  UPDATE public.profiles
     SET account_id = v_account,
         role = 'owner',
         updated_at = now()
   WHERE id = v_uid;

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
  VALUES (v_account, v_uid, ARRAY['dashboard','patients.new','patients.list','employees'])
  ON CONFLICT (account_id, user_uid) DO NOTHING;

  INSERT INTO public.account_subscriptions(account_id, plan_code, status, start_at, end_at, approved_at)
  VALUES (v_account, 'free', 'active', now(), NULL, now());

  PERFORM public.apply_plan_permissions(v_account, 'free');

  RETURN v_account;
END;
$$;
REVOKE ALL ON FUNCTION public.self_create_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO public;

-- 13) User flow: create subscription request
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

  IF NOT EXISTS (SELECT 1 FROM public.subscription_plans WHERE code = v_plan AND is_active = true) THEN
    RAISE EXCEPTION 'plan not found';
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

-- 14) Admin: approve request + activate subscription
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

  RETURN jsonb_build_object('ok', true, 'account_id', r.account_id, 'plan', r.plan_code);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_approve_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription_request(uuid, text) TO public;

-- 15) Admin: change plan directly (monthly/annual/free)
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

  RETURN jsonb_build_object('ok', true, 'account_id', p_account, 'plan', plan.code, 'note', p_note);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_account_plan(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_account_plan(uuid, text, text) TO public;

COMMIT;
