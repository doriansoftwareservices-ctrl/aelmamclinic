-- Return types backed by views so Hasura can expose RPCs in the schema.

DROP FUNCTION IF EXISTS public.my_profile();
DROP FUNCTION IF EXISTS public.my_feature_permissions(uuid);
DROP FUNCTION IF EXISTS public.admin_list_clinics();
DROP FUNCTION IF EXISTS public.list_employees_with_email(uuid);
DROP FUNCTION IF EXISTS public.my_account_id();
DROP FUNCTION IF EXISTS public.admin_set_clinic_frozen(uuid, boolean);
DROP FUNCTION IF EXISTS public.admin_delete_clinic(uuid);
DROP FUNCTION IF EXISTS public.admin_create_owner_full(text, text, text);
DROP FUNCTION IF EXISTS public.admin_create_employee_full(uuid, text, text);
DROP FUNCTION IF EXISTS public.set_employee_disabled(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS public.delete_employee(uuid, uuid);
DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
DROP FUNCTION IF EXISTS public.chat_decline_invitation(uuid, text);
DROP FUNCTION IF EXISTS public.chat_mark_delivered(uuid[]);

CREATE OR REPLACE VIEW public.v_my_account_id AS
SELECT NULL::uuid AS account_id
WHERE false;

CREATE OR REPLACE VIEW public.v_my_profile AS
SELECT
  NULL::uuid AS id,
  NULL::text AS email,
  NULL::text AS role,
  NULL::uuid AS account_id,
  NULL::text AS display_name,
  ARRAY[]::uuid[] AS account_ids
WHERE false;

CREATE OR REPLACE VIEW public.v_my_feature_permissions AS
SELECT
  NULL::uuid AS account_id,
  ARRAY[]::text[] AS allowed_features,
  NULL::boolean AS can_create,
  NULL::boolean AS can_update,
  NULL::boolean AS can_delete
WHERE false;

CREATE OR REPLACE VIEW public.v_admin_list_clinics AS
SELECT
  NULL::uuid AS id,
  NULL::text AS name,
  NULL::boolean AS frozen,
  NULL::timestamptz AS created_at
WHERE false;

CREATE OR REPLACE VIEW public.v_list_employees_with_email AS
SELECT
  NULL::uuid AS user_uid,
  NULL::text AS email,
  NULL::text AS role,
  NULL::boolean AS disabled,
  NULL::timestamptz AS created_at,
  NULL::uuid AS employee_id,
  NULL::uuid AS doctor_id
WHERE false;

CREATE OR REPLACE VIEW public.v_rpc_result AS
SELECT
  NULL::boolean AS ok,
  NULL::text AS error,
  NULL::uuid AS account_id,
  NULL::uuid AS user_uid,
  NULL::uuid AS owner_uid,
  NULL::text AS role,
  NULL::boolean AS frozen,
  NULL::boolean AS disabled
WHERE false;

DROP FUNCTION IF EXISTS public.my_account_id();
CREATE OR REPLACE FUNCTION public.my_account_id()
RETURNS SETOF public.v_my_account_id
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT account_id
  FROM public.account_users
  WHERE user_uid = public.request_uid_text()::uuid
    AND coalesce(disabled, false) = false
  ORDER BY created_at DESC
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.my_account_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.my_profile()
RETURNS SETOF public.v_my_profile
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  with me as (
    select
      u.id,
      u.email,
      p.role as profile_role,
      p.account_id as profile_account_id,
      p.display_name,
      (
        select array_agg(au.account_id order by au.created_at desc)
        from public.account_users au
        where au.user_uid = u.id
          and coalesce(au.disabled, false) = false
      ) as membership_accounts,
      (
        select au.role
        from public.account_users au
        where au.user_uid = u.id
          and coalesce(au.disabled, false) = false
        order by au.created_at desc
        limit 1
      ) as membership_role
    from auth.users u
    left join public.profiles p on p.id = u.id
    where u.id = public.request_uid_text()::uuid
  )
  select
    me.id,
    me.email,
    coalesce(me.profile_role, me.membership_role, 'employee') as role,
    coalesce(
      me.profile_account_id,
      me.membership_accounts[1],
      (select account_id from public.my_account_id() limit 1)
    ) as account_id,
    me.display_name,
    coalesce(me.membership_accounts, array[]::uuid[]) as account_ids
  from me;
$$;
REVOKE ALL ON FUNCTION public.my_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_profile() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.my_feature_permissions(p_account uuid)
RETURNS SETOF public.v_my_feature_permissions
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
declare
  v_uid uuid := public.request_uid_text()::uuid;
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_allowed text[];
  v_can_create boolean;
  v_can_update boolean;
  v_can_delete boolean;
begin
  if v_uid is null then
    return;
  end if;

  if p_account is null then
    return query select null::uuid, array[]::text[], true, true, true;
  end if;

  if not v_is_super then
    if not exists (
      select 1
      from public.account_users au
      where au.account_id = p_account
        and au.user_uid = v_uid
        and coalesce(au.disabled, false) = false
    ) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  select
    coalesce(array_agg(distinct fp.feature), array[]::text[]),
    bool_or(coalesce(fp.can_create, false)),
    bool_or(coalesce(fp.can_update, false)),
    bool_or(coalesce(fp.can_delete, false))
  into v_allowed, v_can_create, v_can_update, v_can_delete
  from public.account_feature_permissions fp
  where fp.account_id = p_account;

  return query select p_account, v_allowed, v_can_create, v_can_update, v_can_delete;
end;
$$;
REVOKE ALL ON FUNCTION public.my_feature_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_list_clinics()
RETURNS SETOF public.v_admin_list_clinics
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
BEGIN
  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT a.id, a.name, a.frozen, a.created_at
  FROM public.accounts a
  ORDER BY a.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_clinics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.list_employees_with_email(p_account uuid)
RETURNS SETOF public.v_list_employees_with_email
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'admin@elmam.com';
  can_manage boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND role IN ('owner','admin')
      AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    au.user_uid,
    coalesce(u.email, au.email),
    au.role,
    coalesce(au.disabled,false) AS disabled,
    au.created_at,
    e.id AS employee_id,
    d.id AS doctor_id
  FROM public.account_users au
  LEFT JOIN auth.users u ON u.id = au.user_uid
  LEFT JOIN public.employees e ON e.user_uid = au.user_uid
  LEFT JOIN public.doctors d ON d.user_uid = au.user_uid
  WHERE au.account_id = p_account
  ORDER BY au.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_employees_with_email(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_employees_with_email(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_set_clinic_frozen(
  p_account_id uuid,
  p_frozen boolean
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
  updated_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN QUERY SELECT false, 'account_id is required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.accounts
     SET frozen = coalesce(p_frozen, false)
   WHERE id = p_account_id
   RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text, updated_id, NULL::uuid, NULL::uuid, NULL::text, coalesce(p_frozen, false), NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_delete_clinic(
  p_account_id uuid
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
  deleted_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN QUERY SELECT false, 'account_id is required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.accounts
   WHERE id = p_account_id
   RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text, deleted_id, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_clinic(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_clinic text := coalesce(nullif(trim(p_clinic_name), ''), '');
  normalized_email text := lower(coalesce(trim(p_owner_email), ''));
  normalized_role text := 'owner';
  normalized_password text := nullif(coalesce(trim(p_owner_password), ''), '');
  owner_uid uuid;
  acc_id uuid;
BEGIN
  IF normalized_clinic = '' OR normalized_email = '' THEN
    RETURN QUERY SELECT false, 'clinic_name and owner_email are required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  owner_uid := public.admin_resolve_or_create_auth_user(
    normalized_email,
    normalized_password,
    normalized_role
  );

  INSERT INTO public.accounts(name, frozen)
  VALUES (normalized_clinic, false)
  RETURNING id INTO acc_id;

  PERFORM public.admin_attach_employee(acc_id, owner_uid, normalized_role);

  UPDATE public.account_users
     SET email = normalized_email,
         role = normalized_role,
         disabled = false,
         updated_at = now()
   WHERE account_id = acc_id
     AND user_uid = owner_uid;

  UPDATE public.profiles
     SET account_id = acc_id,
         role = normalized_role,
         email = normalized_email,
         disabled = false,
         updated_at = now()
   WHERE id = owner_uid;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', acc_id::text
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', acc_id::text,
           'email_verified', true
         )
   WHERE id = owner_uid;

  RETURN QUERY SELECT true, NULL::text, acc_id, owner_uid, owner_uid, normalized_role, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_owner_full(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_email text := lower(coalesce(trim(p_email), ''));
  normalized_role text := 'employee';
  normalized_password text := nullif(coalesce(trim(p_password), ''), '');
  emp_uid uuid;
  account_exists boolean;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_account IS NULL THEN
    RETURN QUERY SELECT false, 'account_id is required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF normalized_email = '' THEN
    RETURN QUERY SELECT false, 'email is required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT EXISTS (
           SELECT 1 FROM public.accounts a WHERE a.id = p_account
         )
    INTO account_exists;

  IF NOT COALESCE(account_exists, false) THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  emp_uid := public.admin_resolve_or_create_auth_user(
    normalized_email,
    normalized_password,
    normalized_role
  );

  PERFORM public.admin_attach_employee(p_account, emp_uid, normalized_role);

  UPDATE public.account_users
     SET email = normalized_email,
         role = normalized_role,
         disabled = false,
         updated_at = now()
   WHERE account_id = p_account
     AND user_uid = emp_uid;

  UPDATE public.profiles
     SET account_id = p_account,
         role = normalized_role,
         email = normalized_email,
         disabled = false,
         updated_at = now()
   WHERE id = emp_uid;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', p_account::text
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', p_account::text,
           'email_verified', true
         )
   WHERE id = emp_uid;

  RETURN QUERY SELECT true, NULL::text, p_account, emp_uid, NULL::uuid, normalized_role, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO public;

DROP FUNCTION IF EXISTS public.set_employee_disabled(uuid, uuid, boolean);
CREATE OR REPLACE FUNCTION public.set_employee_disabled(
  p_account uuid,
  p_user_uid uuid,
  p_disabled boolean
) RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
  target_role text;
BEGIN
  SELECT EXISTS (
    SELECT 1
      FROM public.account_users
     WHERE account_id = p_account
       AND user_uid = caller_uid
       AND lower(coalesce(role,'')) IN ('owner','admin','superadmin')
       AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR is_super_admin) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.account_users
     SET disabled = coalesce(p_disabled, false)
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  SELECT nullif(lower(coalesce(role, '')), '')
    INTO target_role
    FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid
   LIMIT 1;

  UPDATE public.profiles
     SET role = coalesce(target_role, role),
         account_id = coalesce(account_id, p_account),
         disabled = coalesce(p_disabled, false)
   WHERE id = p_user_uid;

  RETURN QUERY SELECT true, NULL::text, p_account, p_user_uid, NULL::uuid, target_role, NULL::boolean, coalesce(p_disabled, false);
END;
$$;
REVOKE ALL ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) TO PUBLIC;

DROP FUNCTION IF EXISTS public.delete_employee(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_employee(
  p_account uuid,
  p_user_uid uuid
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND lower(coalesce(role,'')) in ('owner','admin','superadmin')
      AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR is_super_admin) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  UPDATE public.profiles
     SET role = 'removed'
   WHERE id = p_user_uid
     AND coalesce(account_id, p_account) = p_account;

  RETURN QUERY SELECT true, NULL::text, p_account, p_user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_employee(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.delete_employee(uuid, uuid) TO public;

DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
CREATE OR REPLACE FUNCTION public.chat_accept_invitation(p_invitation_id uuid)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := lower(
    coalesce(current_setting('request.jwt.claims', true)::json ->> 'email', '')
  );
  v_inv record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT inv.*, conv.account_id, conv.created_by
  INTO v_inv
  FROM public.chat_group_invitations inv
  JOIN public.chat_conversations conv ON conv.id = inv.conversation_id
  WHERE inv.id = p_invitation_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation not found' USING errcode = 'P0002';
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN QUERY SELECT false, 'invitation not pending', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF NOT (
    v_inv.invitee_uid = v_uid
    OR (
      v_inv.invitee_uid IS NULL
      AND v_inv.invitee_email IS NOT NULL
      AND lower(v_inv.invitee_email) = v_email
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.chat_group_invitations
     SET status = 'accepted',
         invitee_uid = coalesce(v_inv.invitee_uid, v_uid),
         responded_at = now(),
         response_note = NULL
   WHERE id = p_invitation_id;

  INSERT INTO public.chat_participants (conversation_id, user_uid, email, joined_at)
  VALUES (
    v_inv.conversation_id,
    v_uid,
    NULLIF(v_email, ''),
    now()
  )
  ON CONFLICT (conversation_id, user_uid) DO NOTHING;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

DROP FUNCTION IF EXISTS public.chat_decline_invitation(uuid, text);
CREATE OR REPLACE FUNCTION public.chat_decline_invitation(
  p_invitation_id uuid,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := lower(
    coalesce(current_setting('request.jwt.claims', true)::json ->> 'email', '')
  );
  v_inv record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT *
  INTO v_inv
  FROM public.chat_group_invitations
  WHERE id = p_invitation_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation not found' USING errcode = 'P0002';
  END IF;

  IF NOT (
    v_inv.invitee_uid = v_uid
    OR (
      v_inv.invitee_uid IS NULL
      AND v_inv.invitee_email IS NOT NULL
      AND lower(v_inv.invitee_email) = v_email
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.chat_group_invitations
     SET status = 'declined',
         invitee_uid = coalesce(v_inv.invitee_uid, v_uid),
         responded_at = now(),
         response_note = NULLIF(p_note, '')
   WHERE id = p_invitation_id;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_accept_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_accept_invitation(uuid) TO PUBLIC;

REVOKE ALL ON FUNCTION public.chat_decline_invitation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_decline_invitation(uuid, text) TO PUBLIC;

DROP FUNCTION IF EXISTS public.chat_mark_delivered(uuid[]);
CREATE OR REPLACE FUNCTION public.chat_mark_delivered(p_message_ids uuid[])
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING errcode = '42501';
  END IF;

  INSERT INTO public.chat_delivery_receipts (message_id, conversation_id, user_uid, delivered_at)
  SELECT DISTINCT mid, m.conversation_id, v_uid, now()
  FROM unnest(coalesce(p_message_ids, ARRAY[]::uuid[])) AS mid
  JOIN public.chat_messages m ON m.id = mid
  WHERE m.sender_uid IS DISTINCT FROM v_uid
  ON CONFLICT (message_id, user_uid)
  DO UPDATE SET delivered_at = EXCLUDED.delivered_at;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_mark_delivered(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_mark_delivered(uuid[]) TO PUBLIC;
