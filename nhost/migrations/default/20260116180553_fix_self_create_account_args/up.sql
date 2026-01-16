BEGIN;

DROP FUNCTION IF EXISTS public.self_create_account(text);

CREATE OR REPLACE FUNCTION public.self_create_account(
  p_clinic_name text,
  p_city_ar text,
  p_street_ar text,
  p_near_ar text,
  p_clinic_name_en text,
  p_city_en text,
  p_street_en text,
  p_near_en text,
  p_phone text
)
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
  IF p_city_ar IS NULL OR btrim(p_city_ar) = '' THEN
    RAISE EXCEPTION 'p_city_ar required';
  END IF;
  IF p_street_ar IS NULL OR btrim(p_street_ar) = '' THEN
    RAISE EXCEPTION 'p_street_ar required';
  END IF;
  IF p_near_ar IS NULL OR btrim(p_near_ar) = '' THEN
    RAISE EXCEPTION 'p_near_ar required';
  END IF;
  IF p_clinic_name_en IS NULL OR btrim(p_clinic_name_en) = '' THEN
    RAISE EXCEPTION 'p_clinic_name_en required';
  END IF;
  IF p_city_en IS NULL OR btrim(p_city_en) = '' THEN
    RAISE EXCEPTION 'p_city_en required';
  END IF;
  IF p_street_en IS NULL OR btrim(p_street_en) = '' THEN
    RAISE EXCEPTION 'p_street_en required';
  END IF;
  IF p_near_en IS NULL OR btrim(p_near_en) = '' THEN
    RAISE EXCEPTION 'p_near_en required';
  END IF;
  IF p_phone IS NULL OR btrim(p_phone) = '' THEN
    RAISE EXCEPTION 'p_phone required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.user_uid = v_uid AND au.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'account already exists for this user';
  END IF;

  INSERT INTO public.accounts(
    name,
    clinic_name_en,
    city_ar,
    street_ar,
    near_ar,
    city_en,
    street_en,
    near_en,
    phone
  )
  VALUES (
    p_clinic_name,
    p_clinic_name_en,
    p_city_ar,
    p_street_ar,
    p_near_ar,
    p_city_en,
    p_street_en,
    p_near_en,
    p_phone
  )
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

REVOKE ALL ON FUNCTION public.self_create_account(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) TO PUBLIC;

COMMIT;
