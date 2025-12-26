-- Revert Stage 3 return-type normalization.

BEGIN;

DROP FUNCTION IF EXISTS public.chat_admin_start_dm(text);
DROP FUNCTION IF EXISTS public.create_subscription_request(text, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.self_create_account(text);
DROP FUNCTION IF EXISTS public.account_is_paid_gql(uuid);
DROP VIEW IF EXISTS public.v_bool_result;

-- Restore self_create_account to uuid return.
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

  RETURN v_account;
END;
$$;
REVOKE ALL ON FUNCTION public.self_create_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO public;

-- Restore create_subscription_request to uuid return.
CREATE OR REPLACE FUNCTION public.create_subscription_request(
  p_plan text,
  p_payment_method uuid,
  p_proof_url text DEFAULT NULL,
  p_reference_text text DEFAULT NULL,
  p_sender_name text DEFAULT NULL
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

  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_subscription_request(text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subscription_request(text, uuid, text, text, text) TO public;

-- Restore chat_admin_start_dm to uuid return.
CREATE OR REPLACE FUNCTION public.chat_admin_start_dm(
  target_email text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub', '')::uuid;
  caller_email text := lower(coalesce(claims->>'email', ''));
  is_super boolean := public.fn_is_super_admin();
  normalized_email text := lower(coalesce(target_email, ''));
  target_uid uuid;
  target_account uuid;
  existing_conv uuid;
  conv_id uuid;
  now_ts timestamptz := now();
BEGIN
  IF caller_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'target_email is required';
  END IF;

  IF NOT is_super THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO target_uid
  FROM auth.users
  WHERE lower(email) = normalized_email
  ORDER BY created_at DESC
  LIMIT 1;

  IF target_uid IS NULL THEN
    RAISE EXCEPTION 'target user not found' USING errcode = 'P0002';
  END IF;

  IF target_uid = caller_uid THEN
    RAISE EXCEPTION 'cannot start conversation with yourself';
  END IF;

  SELECT au.account_id
    INTO target_account
  FROM public.account_users au
  WHERE au.user_uid = target_uid
    AND coalesce(au.disabled, false) = false
  ORDER BY CASE WHEN lower(coalesce(au.role, '')) IN ('owner','admin','superadmin') THEN 0 ELSE 1 END,
           au.created_at DESC
  LIMIT 1;

  SELECT p.conversation_id
    INTO existing_conv
  FROM public.chat_participants p
  JOIN public.chat_participants p2
    ON p.conversation_id = p2.conversation_id
  JOIN public.chat_conversations c
    ON c.id = p.conversation_id
  WHERE p.user_uid = caller_uid
    AND p2.user_uid = target_uid
    AND coalesce(c.is_group, false) = false
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF existing_conv IS NOT NULL THEN
    RETURN existing_conv;
  END IF;

  conv_id := gen_random_uuid();

  INSERT INTO public.chat_conversations(id, account_id, is_group, title, created_by, created_at, updated_at)
  VALUES (conv_id, target_account, false, NULL, caller_uid, now_ts, now_ts);

  INSERT INTO public.chat_participants(conversation_id, user_uid, role, email, joined_at)
  VALUES
    (conv_id, caller_uid, 'superadmin', NULLIF(caller_email, ''), now_ts),
    (conv_id, target_uid, NULL, normalized_email, now_ts);

  RETURN conv_id;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_admin_start_dm(text) FROM public;
GRANT EXECUTE ON FUNCTION public.chat_admin_start_dm(text) TO PUBLIC;

COMMIT;
