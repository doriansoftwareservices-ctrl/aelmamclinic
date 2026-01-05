BEGIN;

-- -------------------------------------------------------------------
-- [0] Canonical columns (backward compatible)
-- -------------------------------------------------------------------

ALTER TABLE public.subscription_plans
  ADD COLUMN IF NOT EXISTS grace_days integer NOT NULL DEFAULT 0;

ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS plan_code text;

ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS amount numeric(10,2);

ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS reference_text text;

ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS sender_name text;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='subscription_requests' AND column_name='plan'
  ) THEN
    UPDATE public.subscription_requests
       SET plan_code = coalesce(plan_code, plan)
     WHERE plan_code IS NULL AND plan IS NOT NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='subscription_requests' AND column_name='amount_usd'
  ) THEN
    UPDATE public.subscription_requests
       SET amount = coalesce(amount, amount_usd)
     WHERE amount IS NULL AND amount_usd IS NOT NULL;
  END IF;
END $$;

ALTER TABLE public.account_feature_permissions
  ADD COLUMN IF NOT EXISTS allow_all boolean NOT NULL DEFAULT false;

-- -------------------------------------------------------------------
-- [1] Helpers: membership role checks
-- -------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_is_account_role(
  p_account uuid,
  p_roles text[]
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid = nullif(public.request_uid_text(), '')::uuid
      AND coalesce(au.disabled,false) = false
      AND lower(coalesce(au.role,'')) = ANY (p_roles)
  );
$$;
REVOKE ALL ON FUNCTION public.fn_is_account_role(uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_role(uuid, text[]) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.fn_is_account_owner_or_admin(p_account uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.fn_is_account_role(p_account, ARRAY['owner','admin']::text[]);
$$;
REVOKE ALL ON FUNCTION public.fn_is_account_owner_or_admin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_owner_or_admin(uuid) TO PUBLIC;

-- -------------------------------------------------------------------
-- [2] Plan features: FREE minimal
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.plan_features (
  plan_code   text NOT NULL REFERENCES public.subscription_plans(code) ON DELETE CASCADE,
  feature_key text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_code, feature_key)
);

DELETE FROM public.plan_features WHERE plan_code = 'free' AND feature_key = 'employees';

INSERT INTO public.plan_features(plan_code, feature_key)
VALUES
  ('free','dashboard'),
  ('free','patients.new'),
  ('free','patients.list')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.plan_allowed_features(p_plan text)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH normalized AS (
    SELECT lower(coalesce(p_plan, 'free')) AS code
  ),
  explicit AS (
    SELECT pf.feature_key
    FROM public.plan_features pf
    JOIN normalized n ON pf.plan_code = n.code
  )
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM explicit)
      THEN ARRAY(SELECT feature_key FROM explicit ORDER BY feature_key)
    WHEN (SELECT code FROM normalized) = 'free'
      THEN ARRAY['dashboard','patients.new','patients.list']::text[]
    ELSE ARRAY[]::text[]
  END;
$$;
REVOKE ALL ON FUNCTION public.plan_allowed_features(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.plan_allowed_features(text) TO PUBLIC;

-- -------------------------------------------------------------------
-- [3] Data integrity
-- -------------------------------------------------------------------

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY account_id, user_uid
      ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST, id DESC
    ) AS rn
  FROM public.account_feature_permissions
)
DELETE FROM public.account_feature_permissions p
USING ranked r
WHERE p.id = r.id AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS account_feature_permissions_uix
  ON public.account_feature_permissions(account_id, user_uid);

WITH pending AS (
  SELECT
    id, account_id,
    row_number() OVER (PARTITION BY account_id ORDER BY created_at DESC, id DESC) AS rn
  FROM public.subscription_requests
  WHERE status = 'pending'
)
UPDATE public.subscription_requests r
SET status = 'cancelled',
    note = coalesce(r.note,'') || CASE WHEN r.note IS NULL OR r.note = '' THEN '' ELSE E'\n' END
           || 'auto-cancelled: duplicate pending request',
    updated_at = now()
FROM pending p
WHERE r.id = p.id AND p.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS subscription_requests_pending_uix
  ON public.subscription_requests(account_id)
  WHERE status = 'pending';

WITH active AS (
  SELECT
    id, account_id,
    row_number() OVER (PARTITION BY account_id ORDER BY created_at DESC, id DESC) AS rn
  FROM public.account_subscriptions
  WHERE status = 'active'
)
UPDATE public.account_subscriptions s
SET status = 'expired',
    updated_at = now()
FROM active a
WHERE s.id = a.id AND a.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS account_subscriptions_active_uix
  ON public.account_subscriptions(account_id)
  WHERE status = 'active';

-- -------------------------------------------------------------------
-- [4] apply_plan_permissions: UPSERT for all members (owner allow_all)
-- -------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_plan_permissions(
  p_account uuid,
  p_plan text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_features text[] := public.plan_allowed_features(p_plan);
BEGIN
  IF p_account IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.account_feature_permissions(
    account_id, user_uid, allow_all, allowed_features, can_create, can_update, can_delete, created_at, updated_at
  )
  SELECT
    au.account_id,
    au.user_uid,
    (lower(coalesce(au.role,'')) = 'owner') AS allow_all,
    CASE WHEN lower(coalesce(au.role,'')) = 'owner' THEN ARRAY[]::text[] ELSE v_features END,
    true, true, true, now(), now()
  FROM public.account_users au
  WHERE au.account_id = p_account
    AND coalesce(au.disabled,false) = false
  ON CONFLICT (account_id, user_uid) DO UPDATE
    SET allow_all        = EXCLUDED.allow_all,
        allowed_features = EXCLUDED.allowed_features,
        can_create       = EXCLUDED.can_create,
        can_update       = EXCLUDED.can_update,
        can_delete       = EXCLUDED.can_delete,
        updated_at       = now();
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO PUBLIC;

-- -------------------------------------------------------------------
-- [5] RLS hardening: owner/admin only for subscription_requests insert
-- -------------------------------------------------------------------

ALTER TABLE public.subscription_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_requests_insert ON public.subscription_requests;
CREATE POLICY subscription_requests_insert
ON public.subscription_requests
FOR INSERT TO PUBLIC
WITH CHECK (
  public.fn_is_super_admin() = true
  OR (
    public.fn_is_account_owner_or_admin(subscription_requests.account_id)
    AND subscription_requests.user_uid = nullif(public.request_uid_text(), '')::uuid
  )
);

-- -------------------------------------------------------------------
-- [6] Unified RPCs
-- -------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_subscription_request(
  hasura_session json,
  p_plan text,
  p_payment_method uuid,
  p_proof_url text DEFAULT NULL,
  p_reference_text text DEFAULT NULL,
  p_sender_name text DEFAULT NULL
)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_plan text := lower(coalesce(p_plan,''));
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

  IF NOT public.fn_is_account_owner_or_admin(v_account) THEN
    RAISE EXCEPTION 'forbidden (only owner/admin can request a plan)' USING ERRCODE = '42501';
  END IF;

  IF v_plan = '' OR v_plan = 'free' THEN
    RAISE EXCEPTION 'invalid plan';
  END IF;

  IF p_payment_method IS NULL THEN
    RAISE EXCEPTION 'payment_method is required';
  END IF;

  SELECT sp.price_usd INTO v_price
  FROM public.subscription_plans sp
  WHERE sp.code = v_plan AND sp.is_active = true
  LIMIT 1;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'plan not found';
  END IF;

  SELECT id INTO v_pending
  FROM public.subscription_requests
  WHERE account_id = v_account AND status = 'pending'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_pending IS NOT NULL THEN
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
    'pending'
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    v_account, v_uid, 'subscription_requests', 'plan.request', v_id::text,
    jsonb_build_object(
      'plan', v_plan,
      'amount', v_price,
      'payment_method_id', p_payment_method,
      'proof_url', p_proof_url,
      'reference_text', p_reference_text,
      'sender_name', p_sender_name
    )
  );

  RETURN QUERY SELECT v_id::uuid AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.user_cancel_subscription_request(
  hasura_session json,
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
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO r
  FROM public.subscription_requests
  WHERE id = p_request
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF r.status <> 'pending' THEN
    RETURN QUERY SELECT false, 'only pending requests can be cancelled', r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF r.user_uid <> v_uid THEN
    RETURN QUERY SELECT false, 'forbidden', r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF NOT public.fn_is_account_owner_or_admin(r.account_id) THEN
    RETURN QUERY SELECT false, 'forbidden (only owner/admin)', r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE public.subscription_requests
     SET status = 'cancelled',
         note = p_note,
         updated_at = now()
   WHERE id = r.id;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    r.account_id, v_uid, 'subscription_requests', 'plan.cancel', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note)
  );

  RETURN QUERY SELECT true, NULL::text, r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.user_cancel_subscription_request(json, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.user_cancel_subscription_request(json, uuid, text) TO PUBLIC;

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
  v_amount numeric(10,2);
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'forbidden', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT * INTO r
  FROM public.subscription_requests
  WHERE id = p_request
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF r.status <> 'pending' THEN
    RETURN QUERY SELECT false, 'request already processed', r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT * INTO plan
  FROM public.subscription_plans
  WHERE code = r.plan_code
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN QUERY SELECT false, 'plan not found', r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF coalesce(plan.duration_months, 0) > 0 THEN
    v_end := v_start + (plan.duration_months::text || ' months')::interval;
  END IF;

  v_amount := coalesce(r.amount, plan.price_usd, 0);

  UPDATE public.subscription_requests
     SET status = 'approved',
         note = p_note,
         reviewed_by = v_uid,
         reviewed_at = now(),
         amount = v_amount,
         updated_at = now()
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

  IF coalesce(v_amount, 0) > 0 THEN
    INSERT INTO public.subscription_payments(
      account_id, request_id, payment_method_id, plan_code, amount, created_by
    )
    VALUES (r.account_id, r.id, r.payment_method_id, r.plan_code, v_amount, v_uid);
  END IF;

  PERFORM public.apply_plan_permissions(r.account_id, r.plan_code);

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    r.account_id, v_uid, 'account_subscriptions', 'plan.approve', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note, 'amount', v_amount)
  );

  RETURN QUERY SELECT true, NULL::text, r.account_id, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_approve_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription_request(uuid, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.expire_account_subscriptions(
  p_dry_run boolean DEFAULT false
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_count integer := 0;
  s record;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'forbidden', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  FOR s IN
    SELECT
      sub.account_id,
      sub.plan_code,
      sub.end_at,
      coalesce(p.grace_days,0) AS grace_days
    FROM public.account_subscriptions sub
    JOIN public.subscription_plans p ON p.code = sub.plan_code
    WHERE sub.status = 'active'
      AND lower(coalesce(sub.plan_code,'free')) <> 'free'
      AND sub.end_at IS NOT NULL
      AND (sub.end_at + (coalesce(p.grace_days,0)::text || ' days')::interval) <= now()
  LOOP
    v_count := v_count + 1;

    IF p_dry_run THEN
      CONTINUE;
    END IF;

    UPDATE public.account_subscriptions
       SET status = 'expired',
           updated_at = now()
     WHERE account_id = s.account_id
       AND status = 'active';

    IF NOT EXISTS (
      SELECT 1 FROM public.account_subscriptions x
      WHERE x.account_id = s.account_id
        AND x.status = 'active'
        AND lower(coalesce(x.plan_code,'free')) = 'free'
    ) THEN
      INSERT INTO public.account_subscriptions(
        account_id, plan_code, status, start_at, end_at, created_at, updated_at
      ) VALUES (
        s.account_id, 'free', 'active', now(), NULL, now(), now()
      );
    END IF;

    PERFORM public.apply_plan_permissions(s.account_id, 'free');

    INSERT INTO public.audit_logs(
      account_id, actor_uid, table_name, op, row_pk, after_row
    ) VALUES (
      s.account_id, v_uid, 'account_subscriptions', 'plan.expire', s.plan_code,
      jsonb_build_object('from', s.plan_code, 'to', 'free')
    );
  END LOOP;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_account_subscriptions(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.expire_account_subscriptions(boolean) TO PUBLIC;

COMMIT;
