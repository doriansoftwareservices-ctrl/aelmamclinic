-- Fix: pass Hasura session variables into key RPCs via session_argument
-- session_argument is a JSON object with keys like 'x-hasura-user-id' (lowercase). :contentReference[oaicite:1]{index=1}

DROP FUNCTION IF EXISTS public.debug_auth_context();

CREATE OR REPLACE FUNCTION public.debug_auth_context(hasura_session json)
RETURNS SETOF public.v_debug_auth_context
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    hasura_session::text AS hasura_user,
    hasura_session::text AS jwt_claims,
    hasura_session->>'x-hasura-user-id' AS jwt_claim_sub,
    hasura_session->>'x-hasura-role' AS jwt_claim_role,
    hasura_session->>'x-hasura-user-id' AS request_uid;
$$;

REVOKE ALL ON FUNCTION public.debug_auth_context(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.debug_auth_context(json) TO PUBLIC;


DROP FUNCTION IF EXISTS public.fn_is_super_admin_gql();

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql(hasura_session json)
RETURNS SETOF public.v_is_super_admin
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT (
    EXISTS (
      SELECT 1
      FROM public.super_admins s
      WHERE s.user_uid = nullif(hasura_session->>'x-hasura-user-id','')::uuid
    )
    OR EXISTS (
      SELECT 1
      FROM public.account_users au
      WHERE au.user_uid = nullif(hasura_session->>'x-hasura-user-id','')::uuid
        AND lower(au.role) = 'superadmin'
        AND coalesce(au.disabled,false) = false
    )
  ) AS is_super_admin;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql(json) TO PUBLIC;


DROP FUNCTION IF EXISTS public.my_account_id();

CREATE OR REPLACE FUNCTION public.my_account_id(hasura_session json)
RETURNS SETOF public.v_uuid_result
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    au.account_id AS value
  FROM public.account_users au
  WHERE au.user_uid = nullif(coalesce(hasura_session->>'x-hasura-user-id', public.request_uid_text()), '')::uuid
    AND coalesce(au.disabled,false) = false
  ORDER BY au.created_at DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.my_account_id(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id(json) TO PUBLIC;


DROP FUNCTION IF EXISTS public.my_profile();

CREATE OR REPLACE FUNCTION public.my_profile(hasura_session json)
RETURNS SETOF public.v_me_profile
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
  SELECT
    u.id,
    lower(u.email) AS email,
    coalesce(
      (SELECT role FROM public.account_users au
       WHERE au.user_uid = u.id
         AND coalesce(au.disabled,false) = false
       ORDER BY au.created_at DESC
       LIMIT 1),
      'user'
    ) AS role,
    (SELECT value FROM public.my_account_id(hasura_session) LIMIT 1) AS account_id
  FROM auth.users u
  WHERE u.id = nullif(coalesce(hasura_session->>'x-hasura-user-id', public.request_uid_text()), '')::uuid
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.my_profile(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_profile(json) TO PUBLIC;


DROP FUNCTION IF EXISTS public.self_create_account(text);

CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text, hasura_session json)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(coalesce(hasura_session->>'x-hasura-user-id', public.request_uid_text()), '')::uuid;
  v_email text;
  v_account uuid;
  v_clinic uuid;
  v_now timestamptz := now();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  SELECT lower(u.email) INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'user email missing';
  END IF;

  -- Existing accounts? return latest
  SELECT au.account_id INTO v_account
  FROM public.account_users au
  WHERE au.user_uid = v_uid
    AND coalesce(au.disabled,false) = false
  ORDER BY au.created_at DESC
  LIMIT 1;

  IF v_account IS NOT NULL THEN
    RETURN v_account;
  END IF;

  INSERT INTO public.accounts (name, created_at)
  VALUES (coalesce(nullif(trim(p_clinic_name), ''), 'My Clinic'), v_now)
  RETURNING id INTO v_account;

  INSERT INTO public.account_users (account_id, user_uid, role, created_at)
  VALUES (v_account, v_uid, 'owner', v_now);

  INSERT INTO public.clinics (account_id, name, created_at)
  VALUES (v_account, coalesce(nullif(trim(p_clinic_name), ''), 'My Clinic'), v_now)
  RETURNING id INTO v_clinic;

  INSERT INTO public.profiles (account_id, user_uid, email, created_at)
  VALUES (v_account, v_uid, v_email, v_now);

  -- IMPORTANT: set Hasura claims + app metadata properly
  PERFORM public.auth_set_user_claims(v_uid, 'owner', v_account);

  INSERT INTO public.permissions (account_id, user_uid, is_owner, created_at)
  VALUES (v_account, v_uid, true, v_now);

  INSERT INTO public.account_subscriptions (account_id, plan, status, started_at, created_at)
  VALUES (v_account, 'free', 'active', v_now, v_now);

  INSERT INTO public.account_settings (account_id, created_at)
  VALUES (v_account, v_now);

  RETURN v_account;
END;
$$;

REVOKE ALL ON FUNCTION public.self_create_account(text, json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text, json) TO PUBLIC;
