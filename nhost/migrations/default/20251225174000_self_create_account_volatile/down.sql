-- Revert to definition without explicit VOLATILE (keeps body unchanged).

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
