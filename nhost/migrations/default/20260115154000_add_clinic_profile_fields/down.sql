BEGIN;

DROP FUNCTION IF EXISTS public.self_create_account(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
);

CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF p_clinic_name IS NULL OR btrim(p_clinic_name) = '' THEN
    RAISE EXCEPTION 'p_clinic_name required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.user_uid = v_uid AND au.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'account already exists for this user';
  END IF;

  INSERT INTO public.accounts(name)
  VALUES (p_clinic_name)
  RETURNING id INTO v_account;

  INSERT INTO public.account_users(user_uid, account_id, role, disabled)
  VALUES (v_uid, v_account, 'owner', false)
  ON CONFLICT (user_uid, account_id) DO UPDATE
  SET role = excluded.role,
      disabled = excluded.disabled;

  INSERT INTO public.profiles(id, email, role, account_id)
  SELECT v_uid, u.email, 'owner', v_account
  FROM auth.users u
  WHERE u.id = v_uid
  ON CONFLICT (id) DO UPDATE
  SET role = 'owner',
      account_id = v_account;

  IF to_regclass('public.account_subscriptions') IS NOT NULL THEN
    INSERT INTO public.account_subscriptions(
      account_id,
      plan_code,
      status,
      start_at,
      end_at,
      approved_at
    )
    SELECT v_account, 'free', 'active', now(), NULL, now()
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.account_subscriptions s
      WHERE s.account_id = v_account AND s.status = 'active'
    );
  END IF;

  PERFORM public.apply_plan_permissions(v_account, 'free');
  PERFORM public.auth_set_user_claims(v_uid, 'owner', v_account);

  RETURN QUERY SELECT v_account::uuid AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.self_create_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO PUBLIC;

ALTER TABLE public.accounts
  DROP COLUMN IF EXISTS clinic_name_en,
  DROP COLUMN IF EXISTS city_ar,
  DROP COLUMN IF EXISTS street_ar,
  DROP COLUMN IF EXISTS near_ar,
  DROP COLUMN IF EXISTS city_en,
  DROP COLUMN IF EXISTS street_en,
  DROP COLUMN IF EXISTS near_en,
  DROP COLUMN IF EXISTS phone;

COMMIT;
