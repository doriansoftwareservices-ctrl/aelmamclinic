-- Restore RPCs to previous scalar/jsonb/void signatures.

CREATE OR REPLACE FUNCTION public.my_account_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  select account_id
  from public.account_users
  where user_uid = nullif(public.request_uid_text(), '')::uuid
    and coalesce(disabled, false) = false
  order by created_at desc
  limit 1;
$$;
REVOKE ALL ON FUNCTION public.my_account_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id() TO public;

CREATE OR REPLACE FUNCTION public.admin_set_clinic_frozen(
  p_account_id uuid,
  p_frozen boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
  updated_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.accounts
     SET frozen = coalesce(p_frozen, false)
   WHERE id = p_account_id
   RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', updated_id::text, 'frozen', coalesce(p_frozen, false));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_delete_clinic(
  p_account_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
  deleted_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.accounts
   WHERE id = p_account_id
   RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', deleted_id::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_clinic(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text DEFAULT NULL
)
RETURNS jsonb
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
    RETURN jsonb_build_object('ok', false, 'error', 'clinic_name and owner_email are required');
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

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', acc_id::text,
    'owner_uid', owner_uid::text,
    'user_uid', owner_uid::text,
    'role', normalized_role
  );
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
RETURNS jsonb
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
    RAISE EXCEPTION 'account_id is required';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'email is required';
  END IF;

  SELECT EXISTS (
           SELECT 1 FROM public.accounts a WHERE a.id = p_account
         )
    INTO account_exists;

  IF NOT COALESCE(account_exists, false) THEN
    RAISE EXCEPTION 'account % not found', p_account;
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

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', p_account::text,
    'user_uid', emp_uid::text,
    'role', normalized_role
  );
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
) RETURNS void
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
END;
$$;
REVOKE ALL ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) TO PUBLIC;

DROP FUNCTION IF EXISTS public.delete_employee(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_employee(
  p_account uuid,
  p_user_uid uuid
)
returns void as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
begin
  select exists (
    select 1
    from public.account_users
    where account_id = p_account
      and user_uid = caller_uid
      and lower(coalesce(role,'')) in ('owner','admin','superadmin')
      and coalesce(disabled,false) = false
  ) into can_manage;

  if not (can_manage or is_super_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.account_users
   where account_id = p_account
     and user_uid = p_user_uid;

  update public.profiles
     set role = 'removed'
   where id = p_user_uid
     and coalesce(account_id, p_account) = p_account;
end;
$$ language plpgsql
security definer
set search_path = public, auth;
revoke all on function public.delete_employee(uuid, uuid) from public;
grant execute on function public.delete_employee(uuid, uuid) TO public;

DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
CREATE OR REPLACE FUNCTION public.chat_accept_invitation(p_invitation_id uuid)
RETURNS jsonb
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
    RETURN jsonb_build_object('ok', false, 'error', 'invitation not pending');
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

  RETURN jsonb_build_object('ok', true);
END;
$$;

DROP FUNCTION IF EXISTS public.chat_decline_invitation(uuid, text);
CREATE OR REPLACE FUNCTION public.chat_decline_invitation(
  p_invitation_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
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

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.chat_accept_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_accept_invitation(uuid) TO PUBLIC;

REVOKE ALL ON FUNCTION public.chat_decline_invitation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_decline_invitation(uuid, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.chat_mark_delivered(p_message_ids uuid[])
RETURNS void
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
END;
$$;

REVOKE ALL ON FUNCTION public.chat_mark_delivered(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_mark_delivered(uuid[]) TO PUBLIC;
