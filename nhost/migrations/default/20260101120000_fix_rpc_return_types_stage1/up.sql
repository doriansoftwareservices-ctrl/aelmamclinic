-- Align critical RPC return types with deployed backend (SETOF views).

BEGIN;

-- Ensure incompatible signatures are removed before redefining.
DROP FUNCTION IF EXISTS public.self_create_account(text);
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, numeric, text, text, text);
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.expire_account_subscriptions();
DROP FUNCTION IF EXISTS public.expire_account_subscriptions(boolean);

-- self_create_account: return SETOF v_uuid_result.
CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
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

-- create_subscription_request: return SETOF v_uuid_result (server-priced).
CREATE OR REPLACE FUNCTION public.create_subscription_request(
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
  v_plan text := lower(coalesce(p_plan, ''));
  v_amount numeric;
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

  SELECT price_usd INTO v_amount
  FROM public.subscription_plans
  WHERE code = v_plan AND is_active = true;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'plan price not found';
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
    reference_text,
    sender_name,
    status
  )
  VALUES (
    v_account,
    v_uid,
    v_plan,
    p_payment_method,
    v_amount,
    p_proof_url,
    nullif(trim(coalesce(p_reference_text, '')), ''),
    nullif(trim(coalesce(p_sender_name, '')), ''),
    'pending'
  )
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_subscription_request(text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(text, uuid, text, text, text) TO public;

-- expire_account_subscriptions: return SETOF v_rpc_result.
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

COMMIT;
