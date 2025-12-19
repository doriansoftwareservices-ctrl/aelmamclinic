-- Prevent duplicate invitations per conversation.
-- Adds unique indexes for invitee_uid and invitee_email and cleans existing duplicates.

DO $$
BEGIN
  -- Remove duplicate rows targeting the same user UID.
  DELETE FROM public.chat_group_invitations a
  USING public.chat_group_invitations b
  WHERE a.id > b.id
    AND a.conversation_id = b.conversation_id
    AND a.invitee_uid IS NOT NULL
    AND b.invitee_uid IS NOT NULL
    AND a.invitee_uid = b.invitee_uid;

  -- Remove duplicates for email-only invites (no invitee_uid yet).
  DELETE FROM public.chat_group_invitations a
  USING public.chat_group_invitations b
  WHERE a.id > b.id
    AND a.conversation_id = b.conversation_id
    AND a.invitee_uid IS NULL AND b.invitee_uid IS NULL
    AND a.invitee_email IS NOT NULL AND b.invitee_email IS NOT NULL
    AND lower(a.invitee_email) = lower(b.invitee_email);
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cgi_conversation_invitee_uid
  ON public.chat_group_invitations(conversation_id, invitee_uid)
  WHERE invitee_uid IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cgi_conversation_invitee_email
  ON public.chat_group_invitations(conversation_id, lower(invitee_email))
  WHERE invitee_uid IS NULL AND invitee_email IS NOT NULL;
