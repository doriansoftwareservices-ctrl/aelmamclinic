BEGIN;

-- Remove legacy complaints policies that conflict with the current billing RLS.
DROP POLICY IF EXISTS complaints_select_member_or_super ON public.complaints;
DROP POLICY IF EXISTS complaints_insert_member_or_super ON public.complaints;
DROP POLICY IF EXISTS complaints_update_member_or_super ON public.complaints;
DROP POLICY IF EXISTS complaints_delete_member_or_super ON public.complaints;

-- Remove legacy chat policies (superseded by 20260102110000_chat_rls_policies).
-- chat_conversations
DROP POLICY IF EXISTS conv_select_participant_or_super ON public.chat_conversations;
DROP POLICY IF EXISTS conv_insert_creator_with_account_guard ON public.chat_conversations;
DROP POLICY IF EXISTS conv_update_creator_or_super ON public.chat_conversations;

-- chat_participants
DROP POLICY IF EXISTS parts_select_if_conversation_member_or_super ON public.chat_participants;
DROP POLICY IF EXISTS parts_insert_by_conv_creator_or_super ON public.chat_participants;
DROP POLICY IF EXISTS parts_update_by_conv_creator_or_super ON public.chat_participants;
DROP POLICY IF EXISTS parts_delete_by_conv_creator_or_super ON public.chat_participants;
DROP POLICY IF EXISTS part_select_self_or_super ON public.chat_participants;
DROP POLICY IF EXISTS part_update_self_or_super ON public.chat_participants;
DROP POLICY IF EXISTS part_insert_by_creator_or_super ON public.chat_participants;
DROP POLICY IF EXISTS part_delete_by_creator_or_super ON public.chat_participants;

-- chat_messages
DROP POLICY IF EXISTS msgs_select_if_participant_or_super ON public.chat_messages;
DROP POLICY IF EXISTS msgs_insert_sender_is_self_and_member ON public.chat_messages;
DROP POLICY IF EXISTS msgs_update_owner_or_super ON public.chat_messages;
DROP POLICY IF EXISTS msgs_delete_owner_or_super ON public.chat_messages;
DROP POLICY IF EXISTS chat_read_by_participants ON public.chat_messages;
DROP POLICY IF EXISTS chat_write_service_only ON public.chat_messages;

-- chat_reads
DROP POLICY IF EXISTS reads_select_self_or_super_if_member ON public.chat_reads;
DROP POLICY IF EXISTS reads_insert_self_if_member ON public.chat_reads;
DROP POLICY IF EXISTS reads_update_self_or_super_if_member ON public.chat_reads;

-- chat_attachments
DROP POLICY IF EXISTS atts_select_if_participant_or_super ON public.chat_attachments;
DROP POLICY IF EXISTS atts_insert_if_participant_or_super ON public.chat_attachments;
DROP POLICY IF EXISTS atts_delete_owner_message_or_super ON public.chat_attachments;
DROP POLICY IF EXISTS chat_attachments_insert_participant ON public.chat_attachments;
DROP POLICY IF EXISTS chat_attachments_delete_participant ON public.chat_attachments;

COMMIT;
