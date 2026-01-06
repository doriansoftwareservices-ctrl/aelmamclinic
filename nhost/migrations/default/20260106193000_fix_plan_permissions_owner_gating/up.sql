BEGIN;

-- Apply plan features for all members; do not auto-allow all for owners.
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
    account_id,
    user_uid,
    allow_all,
    allowed_features,
    can_create,
    can_update,
    can_delete,
    created_at,
    updated_at
  )
  SELECT
    au.account_id,
    au.user_uid,
    false AS allow_all,
    v_features,
    true,
    true,
    true,
    now(),
    now()
  FROM public.account_users au
  WHERE au.account_id = p_account
    AND coalesce(au.disabled, false) = false
  ON CONFLICT (account_id, user_uid) DO UPDATE
    SET allow_all = EXCLUDED.allow_all,
        allowed_features = EXCLUDED.allowed_features,
        can_create = EXCLUDED.can_create,
        can_update = EXCLUDED.can_update,
        can_delete = EXCLUDED.can_delete,
        updated_at = now();
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO PUBLIC;

-- Ensure self-create account uses FREE plan permissions (no allow-all).
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

-- Backfill permissions for all accounts using their active plan (or free).
DO $$
DECLARE
  r record;
BEGIN
  IF to_regclass('public.accounts') IS NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT
      a.id AS account_id,
      COALESCE(
        (
          SELECT s.plan_code
          FROM public.account_subscriptions s
          WHERE s.account_id = a.id
            AND s.status = 'active'
          ORDER BY s.created_at DESC
          LIMIT 1
        ),
        'free'
      ) AS plan_code
    FROM public.accounts a
  LOOP
    PERFORM public.apply_plan_permissions(r.account_id, r.plan_code);
  END LOOP;
END;
$$;

-- Safety: normalize auth.users roles to allowed set (prevents auth 500s).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'default_role'
  ) THEN
    EXECUTE $sql$
      UPDATE auth.users
      SET default_role = 'user'
      WHERE default_role IS NULL
         OR lower(default_role) NOT IN ('user', 'superadmin', 'anonymous')
    $sql$;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'roles'
  ) THEN
    EXECUTE $sql$
      UPDATE auth.users u
      SET roles = CASE
        WHEN EXISTS (
          SELECT 1 FROM public.super_admins sa
          WHERE sa.user_uid = u.id OR lower(sa.email) = lower(u.email)
        ) THEN ARRAY['user','superadmin']::text[]
        ELSE ARRAY['user']::text[]
      END
    $sql$;
  END IF;
END;
$$;

COMMIT;
