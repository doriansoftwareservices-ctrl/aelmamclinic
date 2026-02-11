BEGIN;

-- Remove chat attachments storage artifacts
DELETE FROM storage.files WHERE bucket_id = 'chat-attachments';
DELETE FROM storage.buckets WHERE id = 'chat-attachments';

-- Drop attachment/group views
DROP VIEW IF EXISTS public.v_chat_messages_with_attachments;
DROP VIEW IF EXISTS public.v_chat_group_invitations_for_me;

-- Drop attachment/group tables
DROP TABLE IF EXISTS public.chat_attachments CASCADE;
DROP TABLE IF EXISTS public.chat_group_invitations CASCADE;

-- Drop group/invitation RPCs
DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
DROP FUNCTION IF EXISTS public.chat_decline_invitation(uuid, text);
DROP FUNCTION IF EXISTS public.chat_group_set_title(uuid, text);
DROP FUNCTION IF EXISTS public.chat_group_set_frozen(uuid, boolean, boolean);
DROP FUNCTION IF EXISTS public.chat_group_set_member_role(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.chat_group_remove_member(uuid, uuid);
DROP FUNCTION IF EXISTS public.chat_group_delete(uuid);

COMMIT;
