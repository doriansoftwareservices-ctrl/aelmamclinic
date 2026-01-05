BEGIN;

-- CR-LOGIC-1: Fix column name mismatch (amount_usd vs amount) in create_subscription_request.
-- Current broken insert is in: nhost/migrations/default/20260102133000_restore_my_account_id_noarg/up.sql

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
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id', '')::uuid;
  v_account uuid;
  v_plan text := lower(coalesce(p_plan, ''));
  v_amount numeric;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  -- Prefer current account (user_current_account), fallback to latest membership.
  SELECT public.my_account_id() INTO v_account;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'account not found';
  END IF;

  IF v_plan = '' OR v_plan = 'free' THEN
    RAISE EXCEPTION 'invalid plan';
  END IF;

  IF p_payment_method IS NULL THEN
    RAISE EXCEPTION 'payment_method is required';
  END IF;

  -- Secure server-side pricing.
  SELECT price_usd INTO v_amount
  FROM public.subscription_plans
  WHERE code = v_plan AND is_active = true;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'invalid plan pricing';
  END IF;

  -- Prevent duplicate pending requests.
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
    amount,
    payment_method_id,
    proof_url,
    reference_text,
    sender_name,
    status
  ) VALUES (
    v_account,
    v_uid,
    v_plan,
    v_amount,
    p_payment_method,
    nullif(trim(coalesce(p_proof_url, '')), ''),
    nullif(trim(coalesce(p_reference_text, '')), ''),
    nullif(trim(coalesce(p_sender_name, '')), ''),
    'pending'
  )
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(json, text, uuid, text, text, text) TO PUBLIC;

COMMIT;
