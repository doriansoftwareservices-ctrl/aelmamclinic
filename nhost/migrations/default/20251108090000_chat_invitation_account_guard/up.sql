-- 20251108090000_chat_invitation_account_guard.sql
-- Tighten chat invitation acceptance to clinic members and backfill participant account_id.

-- 1) Ensure participant rows carry the clinic account for RLS/FK alignment
UPDATE public.chat_participants p
SET account_id = c.account_id
FROM public.chat_conversations c
WHERE p.account_id IS NULL
  AND p.conversation_id = c.id;

--------------------------------------------------------------------------------
-- 2) Enforce membership during invitation acceptance
--------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
CREATE OR REPLACE FUNCTION public.chat_accept_invitation(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := lower(coalesce(auth.email(), ''));
  v_inv record;
  v_is_member boolean := false;
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

  IF v_inv.account_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.account_users au
      WHERE au.account_id = v_inv.account_id
        AND au.user_uid = v_uid
        AND coalesce(au.disabled, false) = false
    )
    INTO v_is_member;

    IF v_is_member = false AND fn_is_super_admin() = false THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invitee not in account');
    END IF;
  END IF;

  UPDATE public.chat_group_invitations
     SET status = 'accepted',
         invitee_uid = coalesce(v_inv.invitee_uid, v_uid),
         responded_at = now(),
         response_note = NULL
   WHERE id = p_invitation_id;

  INSERT INTO public.chat_participants (account_id, conversation_id, user_uid, email, joined_at)
  VALUES (
    v_inv.account_id,
    v_inv.conversation_id,
    v_uid,
    NULLIF(v_email, ''),
    now()
  )
  ON CONFLICT (conversation_id, user_uid) DO NOTHING;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.chat_accept_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_accept_invitation(uuid) TO PUBLIC;
