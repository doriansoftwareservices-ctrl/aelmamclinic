BEGIN;

-- Restore my_account_id() without session argument to avoid breaking SQL callers.
DROP FUNCTION IF EXISTS public.my_account_id(hasura_session json);

CREATE OR REPLACE FUNCTION public.my_account_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT au.account_id
  FROM public.account_users au
  WHERE au.user_uid = NULLIF(public.request_uid_text(), '')::uuid
  ORDER BY au.created_at DESC
  LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.my_account_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id() TO PUBLIC;

-- Keep create_subscription_request session-aware but avoid calling my_account_id(hasura_session).
DROP FUNCTION IF EXISTS public.create_subscription_request(json, text, uuid, text, text, text);

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

  SELECT au.account_id INTO v_account
  FROM public.account_users au
  WHERE au.user_uid = v_uid
  ORDER BY au.created_at DESC
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
    RAISE EXCEPTION 'invalid plan pricing';
  END IF;

  INSERT INTO public.subscription_requests(
    account_id,
    user_uid,
    plan_code,
    amount_usd,
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
