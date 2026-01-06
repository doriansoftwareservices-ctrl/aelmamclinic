BEGIN;

-- Restore owner allow-all behavior from unify_upgrade_flow_v3.
CREATE OR REPLACE FUNCTION public.apply_plan_permissions(
  p_account uuid,
  p_plan text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_features text[] := public.plan_allowed_features(p_plan);
BEGIN
  IF p_account IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.account_feature_permissions(
    account_id, user_uid, allow_all, allowed_features, can_create, can_update, can_delete, created_at, updated_at
  )
  SELECT
    au.account_id,
    au.user_uid,
    (lower(coalesce(au.role,'')) = 'owner') AS allow_all,
    CASE WHEN lower(coalesce(au.role,'')) = 'owner' THEN ARRAY[]::text[] ELSE v_features END,
    true, true, true, now(), now()
  FROM public.account_users au
  WHERE au.account_id = p_account
    AND coalesce(au.disabled,false) = false
  ON CONFLICT (account_id, user_uid) DO UPDATE
    SET allow_all        = EXCLUDED.allow_all,
        allowed_features = EXCLUDED.allowed_features,
        can_create       = EXCLUDED.can_create,
        can_update       = EXCLUDED.can_update,
        can_delete       = EXCLUDED.can_delete,
        updated_at       = now();
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO PUBLIC;

-- Restore self_create_account seeding allow_all for owners.
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
    WHERE au.user_uid = v_uid and au.role = 'owner'
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

  -- Seed owner feature permissions (allow all)
  INSERT INTO public.account_feature_permissions(
    account_id,
    user_uid,
    allow_all,
    allowed_features,
    can_create,
    can_update,
    can_delete
  ) VALUES (
    v_account,
    v_uid,
    true,
    ARRAY[]::text[],
    true,
    true,
    true
  )
  ON CONFLICT (account_id, user_uid) DO UPDATE
  SET allow_all = true,
      can_create = true,
      can_update = true,
      can_delete = true;

  PERFORM public.auth_set_user_claims(v_uid, 'owner', v_account);

  RETURN QUERY SELECT v_account::uuid AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.self_create_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO PUBLIC;

COMMIT;
