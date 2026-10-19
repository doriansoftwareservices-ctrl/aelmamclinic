BEGIN;

-- A cross-clinic conversation has no single owning clinic. Keep the file's
-- scope equal to that conversation, rather than inventing the viewer's clinic.
-- No existing ownership row is moved, backfilled, or removed by this migration.
ALTER TABLE public.chat_attachment_file_ownership
  ALTER COLUMN account_id DROP NOT NULL;

-- Private authority shared by the attachment Functions and the final file
-- claim. This is not a Hasura-tracked API or a grant to a client role.
CREATE OR REPLACE FUNCTION public.chat_attachment_access_context(
  p_conversation_id uuid,
  p_actor_uid uuid
)
RETURNS TABLE (
  account_id uuid,
  participant_role text,
  allowed boolean,
  is_superadmin boolean,
  account_frozen boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
  WITH context AS (
    SELECT c.account_id,
           coalesce(p.role, '') AS participant_role,
           p.user_uid IS NOT NULL AS participant,
           coalesce(a.frozen, false) AS account_frozen,
           EXISTS (
             SELECT 1 FROM auth.users u
             WHERE u.id = p_actor_uid AND u.disabled IS DISTINCT FROM true
           ) AS active_user,
           EXISTS (
             SELECT 1 FROM public.super_admins sa
             JOIN auth.users u ON u.id = sa.user_uid
             WHERE sa.user_uid = p_actor_uid
               AND sa.disabled IS DISTINCT FROM true
               AND u.disabled IS DISTINCT FROM true
           ) AS active_superadmin,
           EXISTS (
             SELECT 1 FROM public.account_users au
             JOIN public.accounts member_account ON member_account.id = au.account_id
             WHERE au.user_uid = p_actor_uid
               AND au.disabled IS DISTINCT FROM true
               AND member_account.frozen IS DISTINCT FROM true
               AND (
                 au.account_id = c.account_id
                 OR (c.account_id IS NULL AND lower(coalesce(au.role, '')) IN ('owner', 'admin'))
               )
           ) AS active_member
    FROM public.chat_conversations c
    LEFT JOIN public.accounts a ON a.id = c.account_id
    LEFT JOIN public.chat_participants p
      ON p.conversation_id = c.id AND p.user_uid = p_actor_uid
     AND p.is_deleted IS DISTINCT FROM true
    WHERE c.id = p_conversation_id
  )
  SELECT context.account_id, context.participant_role,
         context.active_user AND NOT context.account_frozen
           AND ((context.participant AND context.active_member) OR context.active_superadmin),
         context.active_superadmin, context.account_frozen
  FROM context;
$function$;

REVOKE ALL ON FUNCTION public.chat_attachment_access_context(uuid, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.assert_chat_attachment_file_ownership()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  expected_account_id uuid;
  expected_conversation_id uuid;
BEGIN
  SELECT c.account_id, m.conversation_id
    INTO expected_account_id, expected_conversation_id
  FROM public.chat_messages m
  JOIN public.chat_conversations c ON c.id = m.conversation_id
  WHERE m.id = NEW.message_id;

  IF expected_conversation_id IS NULL
     OR expected_account_id IS DISTINCT FROM NEW.account_id
     OR expected_conversation_id IS DISTINCT FROM NEW.conversation_id THEN
    RAISE EXCEPTION 'chat attachment ownership scope mismatch' USING ERRCODE = '23514';
  END IF;
  NEW.file_name := btrim(NEW.file_name);
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.claim_chat_attachment_file(
  p_file_id uuid,
  p_bucket_id text,
  p_file_name text,
  p_account_id uuid,
  p_conversation_id uuid,
  p_message_id uuid,
  p_uploaded_by_user_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  existing public.chat_attachment_file_ownership%ROWTYPE;
  normalized_name text := btrim(coalesce(p_file_name, ''));
  message_sender uuid;
  actor_allowed boolean;
  actor_superadmin boolean;
  actor_role text;
BEGIN
  IF p_file_id IS NULL OR p_conversation_id IS NULL OR p_message_id IS NULL
     OR p_uploaded_by_user_id IS NULL OR normalized_name = ''
     OR p_bucket_id IS NULL OR p_bucket_id NOT IN ('chat-images', 'chat-attachments') THEN
    RETURN 'invalid_input';
  END IF;

  SELECT m.sender_uid INTO message_sender
  FROM public.chat_messages m
  JOIN public.chat_conversations c ON c.id = m.conversation_id
  WHERE m.id = p_message_id AND m.conversation_id = p_conversation_id
    AND c.account_id IS NOT DISTINCT FROM p_account_id
    AND m.is_deleted IS DISTINCT FROM true AND m.deleted IS DISTINCT FROM true;
  IF NOT FOUND THEN RETURN 'invalid_scope'; END IF;

  -- Storage upload may have waited while a membership or identity was revoked.
  SELECT access.allowed, access.is_superadmin, access.participant_role
    INTO actor_allowed, actor_superadmin, actor_role
  FROM public.chat_attachment_access_context(p_conversation_id, p_uploaded_by_user_id) access;
  IF actor_allowed IS DISTINCT FROM true THEN RETURN 'forbidden'; END IF;
  IF message_sender IS DISTINCT FROM p_uploaded_by_user_id
     AND actor_superadmin IS DISTINCT FROM true
     AND (p_account_id IS NULL OR lower(coalesce(actor_role, '')) NOT IN ('owner', 'admin', 'superadmin')) THEN
    RETURN 'forbidden';
  END IF;

  SELECT o.* INTO existing
  FROM public.chat_attachment_file_ownership o
  WHERE o.file_id = p_file_id
     OR (o.bucket_id = p_bucket_id AND o.file_name = normalized_name)
  ORDER BY CASE WHEN o.file_id = p_file_id THEN 0 ELSE 1 END
  LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF existing.security_state <> 'active' THEN RETURN 'quarantined'; END IF;
    IF existing.account_id IS NOT DISTINCT FROM p_account_id
       AND existing.conversation_id = p_conversation_id AND existing.message_id = p_message_id
       AND existing.bucket_id = p_bucket_id AND existing.file_name = normalized_name
       AND (existing.file_id IS NULL OR existing.file_id = p_file_id)
       AND (existing.uploaded_by_user_id IS NULL OR existing.uploaded_by_user_id = p_uploaded_by_user_id) THEN
      UPDATE public.chat_attachment_file_ownership
      SET file_id = coalesce(file_id, p_file_id),
          uploaded_by_user_id = coalesce(uploaded_by_user_id, p_uploaded_by_user_id),
          updated_at = now()
      WHERE id = existing.id;
      RETURN 'linked';
    END IF;
    RETURN 'conflict';
  END IF;

  BEGIN
    INSERT INTO public.chat_attachment_file_ownership(
      file_id, bucket_id, file_name, account_id, conversation_id, message_id,
      uploaded_by_user_id, security_state, source
    ) VALUES (
      p_file_id, p_bucket_id, normalized_name, p_account_id, p_conversation_id,
      p_message_id, p_uploaded_by_user_id, 'active', 'function'
    );
    RETURN 'linked';
  EXCEPTION WHEN unique_violation THEN
    SELECT o.* INTO existing
    FROM public.chat_attachment_file_ownership o
    WHERE o.file_id = p_file_id
       OR (o.bucket_id = p_bucket_id AND o.file_name = normalized_name)
    ORDER BY CASE WHEN o.file_id = p_file_id THEN 0 ELSE 1 END LIMIT 1;
    IF FOUND AND existing.security_state = 'active'
       AND existing.account_id IS NOT DISTINCT FROM p_account_id
       AND existing.conversation_id = p_conversation_id AND existing.message_id = p_message_id
       AND existing.bucket_id = p_bucket_id AND existing.file_name = normalized_name
       AND (existing.file_id IS NULL OR existing.file_id = p_file_id)
       AND (existing.uploaded_by_user_id IS NULL OR existing.uploaded_by_user_id = p_uploaded_by_user_id) THEN
      RETURN 'linked';
    END IF;
    RETURN 'conflict';
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_chat_attachment_file(uuid, text, text, uuid, uuid, uuid, uuid) FROM PUBLIC;
COMMIT;
