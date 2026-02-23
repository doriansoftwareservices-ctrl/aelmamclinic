BEGIN;

-- 1) Deny-by-default for feature permissions (no implicit allow_all).
CREATE OR REPLACE FUNCTION public.my_feature_permissions(p_account uuid)
RETURNS SETOF public.v_my_feature_permissions
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_allow_all boolean;
  v_allowed text[];
  v_can_create boolean;
  v_can_update boolean;
  v_can_delete boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  IF p_account IS NULL THEN
    RETURN QUERY SELECT null::uuid, false, array[]::text[], false, false, false;
  END IF;

  IF NOT v_is_super THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.account_users au
      WHERE au.account_id = p_account
        AND au.user_uid = v_uid
        AND COALESCE(au.disabled, false) = false
    ) THEN
      RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT
    COALESCE(bool_or(COALESCE(fp.allow_all, false)), false),
    COALESCE(array_agg(distinct feat) FILTER (WHERE feat IS NOT NULL), array[]::text[]),
    COALESCE(bool_or(COALESCE(fp.can_create, false)), false),
    COALESCE(bool_or(COALESCE(fp.can_update, false)), false),
    COALESCE(bool_or(COALESCE(fp.can_delete, false)), false)
  INTO v_allow_all, v_allowed, v_can_create, v_can_update, v_can_delete
  FROM public.account_feature_permissions fp
  LEFT JOIN LATERAL unnest(fp.allowed_features) AS feat ON true
  WHERE fp.account_id = p_account
    AND fp.user_uid = v_uid;

  RETURN QUERY SELECT p_account, v_allow_all, v_allowed, v_can_create, v_can_update, v_can_delete;
END;
$$;

CREATE OR REPLACE FUNCTION public.my_feature_permissions_rpc(hasura_session json, p_account uuid)
RETURNS SETOF public.v_my_feature_permissions
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(
    coalesce(hasura_session->>'x-hasura-user-id', public.request_uid_text(), ''),
    ''
  )::uuid;
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_allow_all boolean;
  v_allowed text[];
  v_can_create boolean;
  v_can_update boolean;
  v_can_delete boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  IF p_account IS NULL THEN
    RETURN QUERY SELECT null::uuid, false, array[]::text[], false, false, false;
  END IF;

  IF NOT v_is_super THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.account_users au
      WHERE au.account_id = p_account
        AND au.user_uid = v_uid
        AND COALESCE(au.disabled, false) = false
    ) THEN
      RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT
    COALESCE(bool_or(COALESCE(fp.allow_all, false)), false),
    COALESCE(array_agg(distinct feat) FILTER (WHERE feat IS NOT NULL), array[]::text[]),
    COALESCE(bool_or(COALESCE(fp.can_create, false)), false),
    COALESCE(bool_or(COALESCE(fp.can_update, false)), false),
    COALESCE(bool_or(COALESCE(fp.can_delete, false)), false)
  INTO v_allow_all, v_allowed, v_can_create, v_can_update, v_can_delete
  FROM public.account_feature_permissions fp
  LEFT JOIN LATERAL unnest(fp.allowed_features) AS feat ON true
  WHERE fp.account_id = p_account
    AND fp.user_uid = v_uid;

  RETURN QUERY SELECT p_account, v_allow_all, v_allowed, v_can_create, v_can_update, v_can_delete;
END;
$$;

REVOKE ALL ON FUNCTION public.my_feature_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions(uuid) TO PUBLIC;
REVOKE ALL ON FUNCTION public.my_feature_permissions_rpc(json, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions_rpc(json, uuid) TO PUBLIC;

DO $m$
BEGIN
  -- 2) Avoid overwriting profiles.account_id across accounts.
  EXECUTE $sql$
    CREATE OR REPLACE FUNCTION public.admin_attach_employee(
      p_account uuid,
      p_user_uid uuid,
      p_role text DEFAULT 'employee'
    )
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $$
    DECLARE
      exists_row boolean;
      caller_can_manage boolean;
      normalized_role text := lower(coalesce(p_role, 'employee'));
      is_super boolean := public.fn_is_super_admin();
      active_exists boolean := false;
      staff_count integer := 0;
      approved_extra boolean := false;
    BEGIN
      IF p_account IS NULL OR p_user_uid IS NULL THEN
        RAISE EXCEPTION 'account_id and user_uid are required';
      END IF;

      IF is_super = false THEN
        SELECT EXISTS (
                 SELECT 1
                   FROM public.account_users au
                  WHERE au.account_id = p_account
                    AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
                    AND COALESCE(au.disabled, false) = false
                    AND lower(COALESCE(au.role, '')) = 'owner'
               )
          INTO caller_can_manage;

        IF NOT COALESCE(caller_can_manage, false) THEN
          RAISE EXCEPTION 'insufficient privileges to manage employees for this account'
            USING ERRCODE = '42501';
        END IF;
      END IF;

      IF normalized_role IN ('employee', 'admin') THEN
        IF public.account_is_paid(p_account) IS DISTINCT FROM true THEN
          RAISE EXCEPTION 'plan is free' USING ERRCODE = '42501';
        END IF;

        SELECT EXISTS (
          SELECT 1
            FROM public.account_users au
           WHERE au.account_id = p_account
             AND au.user_uid = p_user_uid
             AND lower(coalesce(au.role, '')) IN ('employee','admin')
             AND coalesce(au.disabled, false) = false
        ) INTO active_exists;

        SELECT count(*)
          INTO staff_count
          FROM public.account_users au
         WHERE au.account_id = p_account
           AND lower(coalesce(au.role, '')) IN ('employee','admin')
           AND coalesce(au.disabled, false) = false;

        IF staff_count >= 5 AND NOT COALESCE(active_exists, false) THEN
          SELECT EXISTS (
            SELECT 1
              FROM public.employee_seat_requests r
             WHERE r.account_id = p_account
               AND r.employee_user_uid = p_user_uid
               AND r.status = 'approved'
               AND r.seat_kind = 'extra'
          ) INTO approved_extra;

          IF NOT COALESCE(approved_extra, false) THEN
            RAISE EXCEPTION 'seat_payment_required' USING ERRCODE = '42501';
          END IF;
        END IF;
      END IF;

      SELECT true INTO exists_row
      FROM public.account_users
      WHERE account_id = p_account
        AND user_uid = p_user_uid
      LIMIT 1;

      IF NOT COALESCE(exists_row, false) THEN
        INSERT INTO public.account_users(account_id, user_uid, role, disabled)
        VALUES (p_account, p_user_uid, COALESCE(p_role, 'employee'), false);
      ELSE
        UPDATE public.account_users
           SET disabled = false,
               role = COALESCE(p_role, role),
               updated_at = now()
         WHERE account_id = p_account
           AND user_uid = p_user_uid;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'profiles'
      ) THEN
        INSERT INTO public.profiles(id, account_id, role, created_at)
        VALUES (p_user_uid, p_account, COALESCE(p_role, 'employee'), now())
        ON CONFLICT (id) DO UPDATE
            SET account_id = CASE
                  WHEN public.profiles.account_id IS NULL
                    OR public.profiles.account_id = EXCLUDED.account_id
                  THEN EXCLUDED.account_id
                  ELSE public.profiles.account_id
                END,
                role = CASE
                  WHEN public.profiles.account_id IS NULL
                    OR public.profiles.account_id = EXCLUDED.account_id
                  THEN EXCLUDED.role
                  ELSE public.profiles.role
                END;
      END IF;
    END;
    $$;
  $sql$;

  EXECUTE 'REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO PUBLIC';

  -- Only patch owner_create_employee_within_limit if its composite type exists.
  IF to_regtype('public.owner_create_employee_result') IS NOT NULL THEN
    EXECUTE $sql$
      CREATE OR REPLACE FUNCTION public.owner_create_employee_within_limit(
        hasura_session json,
        p_email text,
        p_password text
      )
      RETURNS SETOF public.owner_create_employee_result
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path = public, auth
      AS $$
      DECLARE
        v_account uuid;
        v_uid uuid;
        v_emp_uid uuid;
        v_email text := lower(coalesce(p_email, ''));
        v_password text := coalesce(p_password, '');
      BEGIN
        v_uid := nullif(coalesce(hasura_session->>'x-hasura-user-id', public.request_uid_text(), ''), '')::uuid;
        IF v_uid IS NULL THEN
          RETURN QUERY SELECT false, 'not_authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
          RETURN;
        END IF;

        SELECT au.account_id
          INTO v_account
          FROM public.account_users au
         WHERE au.user_uid = v_uid
           AND lower(coalesce(au.role, '')) = 'owner'
           AND coalesce(au.disabled, false) = false
         ORDER BY au.created_at DESC
         LIMIT 1;

        IF v_account IS NULL THEN
          RETURN QUERY SELECT false, 'not_owner', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
          RETURN;
        END IF;

        SELECT u.id INTO v_emp_uid
          FROM auth.users u
         WHERE lower(u.email) = v_email
         LIMIT 1;

        IF v_emp_uid IS NULL THEN
          SELECT id INTO v_emp_uid
            FROM public.admin_create_employee_full(
              v_account,
              v_email,
              v_password,
              'employee'
            )
            LIMIT 1;
        END IF;

        IF v_emp_uid = v_uid THEN
          RETURN QUERY SELECT false, 'cannot_add_self', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
          RETURN;
        END IF;

        INSERT INTO public.account_users(account_id, user_uid, role, disabled, email)
        VALUES (v_account, v_emp_uid, 'employee', false, v_email)
        ON CONFLICT (account_id, user_uid) DO UPDATE
          SET role = excluded.role,
              disabled = excluded.disabled,
              email = COALESCE(excluded.email, public.account_users.email),
              updated_at = now();

        UPDATE public.profiles
           SET account_id = v_account,
               role = 'employee',
               email = v_email,
               disabled = false,
               updated_at = now()
         WHERE id = v_emp_uid
           AND (account_id IS NULL OR account_id = v_account);

        PERFORM public.auth_set_user_claims(v_emp_uid, 'employee', v_account);

        RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, false;
      END;
      $$;
    $sql$;

    EXECUTE 'REVOKE ALL ON FUNCTION public.owner_create_employee_within_limit(json, text, text) FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.owner_create_employee_within_limit(json, text, text) TO PUBLIC';
  ELSE
    RAISE NOTICE 'skip owner_create_employee_within_limit patch: type owner_create_employee_result not present';
  END IF;
END;
$m$;

COMMIT;
