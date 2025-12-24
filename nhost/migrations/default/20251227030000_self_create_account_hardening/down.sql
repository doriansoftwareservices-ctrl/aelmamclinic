-- Revert self_create_account to previous definition

BEGIN;

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

COMMIT;
