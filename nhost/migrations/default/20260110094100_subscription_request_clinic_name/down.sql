BEGIN;

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
    account_id,
    actor_uid,
    actor_email,
    op,
    table_name,
    row_id,
    changes
  )
  VALUES (
    v_account,
    v_uid,
    coalesce(public.request_email_text(), ''),
    'insert',
    'subscription_requests',
    v_id::text,
    jsonb_build_object('plan_code', v_plan, 'amount', v_price)
  );

  RETURN QUERY SELECT v_id::uuid AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text) TO PUBLIC;

ALTER TABLE public.subscription_requests
  DROP COLUMN IF EXISTS clinic_name;

COMMIT;
