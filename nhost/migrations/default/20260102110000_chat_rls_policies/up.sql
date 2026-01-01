BEGIN;

-- Helper: check chat participation.
CREATE OR REPLACE FUNCTION public.chat_is_participant(
  p_conversation uuid,
  p_user uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_participants p
    WHERE p.conversation_id = p_conversation
      AND p.user_uid = p_user
  );
$$;
REVOKE ALL ON FUNCTION public.chat_is_participant(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_is_participant(uuid, uuid) TO PUBLIC;

ALTER TABLE public.chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_attachments ENABLE ROW LEVEL SECURITY;

-- chat_conversations
DROP POLICY IF EXISTS chat_conversations_select ON public.chat_conversations;
CREATE POLICY chat_conversations_select
ON public.chat_conversations
FOR SELECT
USING (
  public.chat_is_participant(
    id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_conversations_insert ON public.chat_conversations;
CREATE POLICY chat_conversations_insert
ON public.chat_conversations
FOR INSERT
WITH CHECK (
  created_by = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS chat_conversations_update ON public.chat_conversations;
CREATE POLICY chat_conversations_update
ON public.chat_conversations
FOR UPDATE
USING (
  public.chat_is_participant(
    id,
    nullif(public.request_uid_text(), '')::uuid
  )
)
WITH CHECK (
  public.chat_is_participant(
    id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

-- chat_participants
DROP POLICY IF EXISTS chat_participants_select ON public.chat_participants;
CREATE POLICY chat_participants_select
ON public.chat_participants
FOR SELECT
USING (
  public.chat_is_participant(
    conversation_id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_participants_insert ON public.chat_participants;
CREATE POLICY chat_participants_insert
ON public.chat_participants
FOR INSERT
WITH CHECK (
  (
    SELECT c.created_by
    FROM public.chat_conversations c
    WHERE c.id = conversation_id
  ) = nullif(public.request_uid_text(), '')::uuid
  OR public.chat_is_participant(
    conversation_id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_participants_update ON public.chat_participants;
CREATE POLICY chat_participants_update
ON public.chat_participants
FOR UPDATE
USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
)
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS chat_participants_delete ON public.chat_participants;
CREATE POLICY chat_participants_delete
ON public.chat_participants
FOR DELETE
USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  OR (
    SELECT c.created_by
    FROM public.chat_conversations c
    WHERE c.id = conversation_id
  ) = nullif(public.request_uid_text(), '')::uuid
);

-- chat_messages
DROP POLICY IF EXISTS chat_messages_select ON public.chat_messages;
CREATE POLICY chat_messages_select
ON public.chat_messages
FOR SELECT
USING (
  public.chat_is_participant(
    conversation_id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_messages_insert ON public.chat_messages;
CREATE POLICY chat_messages_insert
ON public.chat_messages
FOR INSERT
WITH CHECK (
  sender_uid = nullif(public.request_uid_text(), '')::uuid
  AND public.chat_is_participant(
    conversation_id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_messages_update ON public.chat_messages;
CREATE POLICY chat_messages_update
ON public.chat_messages
FOR UPDATE
USING (
  sender_uid = nullif(public.request_uid_text(), '')::uuid
)
WITH CHECK (
  sender_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS chat_messages_delete ON public.chat_messages;
CREATE POLICY chat_messages_delete
ON public.chat_messages
FOR DELETE
USING (
  sender_uid = nullif(public.request_uid_text(), '')::uuid
);

-- chat_reads
DROP POLICY IF EXISTS chat_reads_select ON public.chat_reads;
CREATE POLICY chat_reads_select
ON public.chat_reads
FOR SELECT
USING (
  public.chat_is_participant(
    conversation_id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_reads_insert ON public.chat_reads;
CREATE POLICY chat_reads_insert
ON public.chat_reads
FOR INSERT
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND public.chat_is_participant(
    conversation_id,
    nullif(public.request_uid_text(), '')::uuid
  )
);

DROP POLICY IF EXISTS chat_reads_update ON public.chat_reads;
CREATE POLICY chat_reads_update
ON public.chat_reads
FOR UPDATE
USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
)
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS chat_reads_delete ON public.chat_reads;
CREATE POLICY chat_reads_delete
ON public.chat_reads
FOR DELETE
USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
);

-- chat_attachments
DROP POLICY IF EXISTS chat_attachments_select ON public.chat_attachments;
CREATE POLICY chat_attachments_select
ON public.chat_attachments
FOR SELECT
USING (
  EXISTS (
    SELECT 1
    FROM public.chat_messages m
    WHERE m.id = message_id
      AND public.chat_is_participant(
        m.conversation_id,
        nullif(public.request_uid_text(), '')::uuid
      )
  )
);

DROP POLICY IF EXISTS chat_attachments_insert ON public.chat_attachments;
CREATE POLICY chat_attachments_insert
ON public.chat_attachments
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.chat_messages m
    WHERE m.id = message_id
      AND m.sender_uid = nullif(public.request_uid_text(), '')::uuid
      AND public.chat_is_participant(
        m.conversation_id,
        nullif(public.request_uid_text(), '')::uuid
      )
  )
);

DROP POLICY IF EXISTS chat_attachments_delete ON public.chat_attachments;
CREATE POLICY chat_attachments_delete
ON public.chat_attachments
FOR DELETE
USING (
  EXISTS (
    SELECT 1
    FROM public.chat_messages m
    WHERE m.id = message_id
      AND m.sender_uid = nullif(public.request_uid_text(), '')::uuid
  )
);

COMMIT;
