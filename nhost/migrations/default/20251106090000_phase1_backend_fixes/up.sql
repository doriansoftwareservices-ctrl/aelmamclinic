-- 20251106090000_phase1_backend_fixes.sql
-- Phase 1 backend fixes:
--   1) Restore my_feature_permissions(p_account uuid) so the Flutter app can request
--      feature toggles for the active clinic.
--   2) Re-enable chat attachment uploads/deletions for conversation participants while
--      retaining the service_role policy.
--   3) Align chat_group_invitations with the client expectations and expose helpers
--      (view + RPCs) for listing/accepting/declining invitations.

--------------------------------------------------------------------------------
-- 1) my_feature_permissions signature
--------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_feature_permissions();

CREATE OR REPLACE FUNCTION public.my_feature_permissions(p_account uuid)
RETURNS TABLE (
  account_id       uuid,
  allowed_features text[],
  can_create       boolean,
  can_update       boolean,
  can_delete       boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
declare
  v_uid uuid := public.request_uid_text();
  v_is_super boolean := coalesce(public.fn_is_super_admin(), false)
    or lower(coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '')) = 'superadmin'
    or lower(coalesce(current_setting('request.jwt.claims', true)::json ->> 'email', '')) = 'admin@elmam.com';
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

  if not exists (
    select 1
    from information_schema.tables
    where table_schema = 'public' and table_name = 'account_feature_permissions'
  ) then
    return query select p_account, array[]::text[], true, true, true;
  end if;

  select
    afp.allowed_features,
    afp.can_create,
    afp.can_update,
    afp.can_delete
  into v_allowed, v_can_create, v_can_update, v_can_delete
  from public.account_feature_permissions afp
  where afp.account_id = p_account
    and (afp.user_uid = v_uid or afp.user_uid is null)
  order by case when afp.user_uid = v_uid then 0 else 1 end
  limit 1;

  return query select
    p_account,
    coalesce(v_allowed, array[]::text[]),
    coalesce(v_can_create, true),
    coalesce(v_can_update, true),
    coalesce(v_can_delete, true);
end;
$$;

REVOKE ALL ON FUNCTION public.my_feature_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions(uuid) TO PUBLIC;

--------------------------------------------------------------------------------
-- 2) Storage policies for chat attachments (restore participant access)
--------------------------------------------------------------------------------

DO $storage$
DECLARE lacking boolean := false;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage.objects not found; skipping storage.objects policy changes';
    RETURN;
  END IF;

  BEGIN
    EXECUTE 'set local role supabase_storage_admin';
  EXCEPTION
    WHEN insufficient_privilege THEN
      lacking := true;
    WHEN undefined_object THEN
      lacking := true;
    WHEN invalid_authorization_specification THEN
      lacking := true;
    WHEN invalid_role_specification THEN
      lacking := true;
    WHEN others THEN
      lacking := true;
  END;

  IF lacking THEN
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY';

  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_insert_participant ON storage.objects';
  EXECUTE $q$
    CREATE POLICY chat_attachments_insert_participant
    ON storage.objects
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND public.chat_conversation_id_from_path(name) IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.chat_participants p
        WHERE p.conversation_id = public.chat_conversation_id_from_path(name)
          AND p.user_uid = public.request_uid_text()
      )
    );
  $q$;

  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_delete_participant ON storage.objects';
  EXECUTE $q$
    CREATE POLICY chat_attachments_delete_participant
    ON storage.objects
    FOR DELETE
    TO PUBLIC
    USING (
      bucket_id = 'chat-attachments'
      AND public.chat_conversation_id_from_path(name) IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.chat_participants p
        WHERE p.conversation_id = public.chat_conversation_id_from_path(name)
          AND p.user_uid = public.request_uid_text()
      )
    );
  $q$;

  EXECUTE 'reset role';
END
$storage$;

--------------------------------------------------------------------------------
-- 3) Chat group invitations helpers
--------------------------------------------------------------------------------

-- Rename columns so they align with the Flutter client fields.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_group_invitations'
      AND column_name = 'inviter'
  ) THEN
    EXECUTE 'ALTER TABLE public.chat_group_invitations RENAME COLUMN inviter TO inviter_uid';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_group_invitations'
      AND column_name = 'invitee_user'
  ) THEN
    EXECUTE 'ALTER TABLE public.chat_group_invitations RENAME COLUMN invitee_user TO invitee_uid';
  END IF;
END;
$$;

-- View exposing invitations for the current authenticated user.
CREATE OR REPLACE VIEW public.v_chat_group_invitations_for_me
AS
SELECT
  inv.id,
  inv.conversation_id,
  inv.inviter_uid,
  inv.invitee_uid,
  inv.invitee_email,
  inv.status,
  inv.response_note,
  inv.created_at,
  inv.responded_at,
  conv.title,
  conv.is_group,
  conv.account_id,
  conv.created_by
FROM public.chat_group_invitations inv
JOIN public.chat_conversations conv ON conv.id = inv.conversation_id
WHERE (
    inv.invitee_uid IS NOT NULL AND inv.invitee_uid = public.request_uid_text()
  ) OR (
    inv.invitee_uid IS NULL
    AND inv.invitee_email IS NOT NULL
    AND lower(inv.invitee_email) = lower(coalesce(auth.email(), ''))
  );

--------------------------------------------------------------------------------
-- RPCs: accept / decline
--------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
CREATE OR REPLACE FUNCTION public.chat_accept_invitation(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := public.request_uid_text();
  v_email text := lower(coalesce(auth.email(), ''));
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
  v_uid uuid := public.request_uid_text();
  v_email text := lower(coalesce(auth.email(), ''));
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
