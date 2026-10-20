BEGIN;

-- Local candidate; not applied to production. Signature and ACL stay intact.
CREATE OR REPLACE FUNCTION public.self_create_account(
  p_clinic_name text,
  p_city_ar text,
  p_street_ar text,
  p_near_ar text,
  p_clinic_name_en text,
  p_city_en text,
  p_street_en text,
  p_near_en text,
  p_phone text,
  p_phone2 text DEFAULT NULL
)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_disabled boolean;
  v_membership record;
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

  -- Serialize creation for this authenticated identity, across devices and
  -- both the Function and direct Hasura RPC. The lock lasts for the complete
  -- account/profile/claims/permissions transaction, including any rollback.
  -- Use the existing advisory-lock facility: creation must not require new
  -- UPDATE privileges on Auth's user table or block its session refreshes.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('clinic-owner-onboarding:' || v_uid::text, 0)
  );
  SELECT u.disabled INTO v_disabled
  FROM auth.users u WHERE u.id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;
  IF coalesce(v_disabled, false) THEN
    RAISE EXCEPTION 'user_disabled' USING ERRCODE = '42501';
  END IF;

  SELECT au.account_id, au.role, au.disabled INTO v_membership
  FROM public.account_users au
  WHERE au.user_uid = v_uid
  ORDER BY au.created_at DESC, au.account_id
  LIMIT 1;
  IF FOUND THEN
    IF coalesce(v_membership.disabled, false) THEN
      RAISE EXCEPTION 'user_disabled' USING ERRCODE = '42501';
    END IF;
    IF lower(btrim(coalesce(v_membership.role, ''))) NOT IN ('owner', 'admin') THEN
      RAISE EXCEPTION 'already linked to an account' USING ERRCODE = '42501';
    END IF;
    -- A lost reply or concurrent retry returns the original account. Never
    -- reset a paid plan, re-seed privileges, or overwrite an existing profile.
    RETURN QUERY SELECT v_membership.account_id::uuid AS id;
    RETURN;
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
    phone,
    phone2
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
    p_phone,
    NULLIF(btrim(p_phone2), '')
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

COMMIT;
