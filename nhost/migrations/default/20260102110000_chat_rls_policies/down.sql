BEGIN;

DROP POLICY IF EXISTS chat_attachments_delete ON public.chat_attachments;
DROP POLICY IF EXISTS chat_attachments_insert ON public.chat_attachments;
DROP POLICY IF EXISTS chat_attachments_select ON public.chat_attachments;

DROP POLICY IF EXISTS chat_reads_delete ON public.chat_reads;
DROP POLICY IF EXISTS chat_reads_update ON public.chat_reads;
DROP POLICY IF EXISTS chat_reads_insert ON public.chat_reads;
DROP POLICY IF EXISTS chat_reads_select ON public.chat_reads;

DROP POLICY IF EXISTS chat_messages_delete ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_update ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_insert ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_select ON public.chat_messages;

DROP POLICY IF EXISTS chat_participants_delete ON public.chat_participants;
DROP POLICY IF EXISTS chat_participants_update ON public.chat_participants;
DROP POLICY IF EXISTS chat_participants_insert ON public.chat_participants;
DROP POLICY IF EXISTS chat_participants_select ON public.chat_participants;

DROP POLICY IF EXISTS chat_conversations_update ON public.chat_conversations;
DROP POLICY IF EXISTS chat_conversations_insert ON public.chat_conversations;
DROP POLICY IF EXISTS chat_conversations_select ON public.chat_conversations;

DROP FUNCTION IF EXISTS public.chat_is_participant(uuid, uuid);

COMMIT;
