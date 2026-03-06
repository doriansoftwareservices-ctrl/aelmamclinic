BEGIN;

DROP FUNCTION IF EXISTS public.chat_purge_due_attachments(int);
DROP FUNCTION IF EXISTS public.chat_mark_attachment_opened(uuid, text);
DROP FUNCTION IF EXISTS public.chat_mark_attachment_downloaded(uuid, text);
DROP FUNCTION IF EXISTS public.chat_try_schedule_attachment_purge(uuid);
DROP TRIGGER IF EXISTS chat_attachments_create_targets ON public.chat_attachments;
DROP FUNCTION IF EXISTS public.tg_chat_attachments_create_targets();
DROP FUNCTION IF EXISTS public.chat_register_device(text, text, text);
DROP FUNCTION IF EXISTS public.chat_is_support_conversation(uuid);

ALTER TABLE IF EXISTS public.chat_attachments
  DROP COLUMN IF EXISTS purge_at;
ALTER TABLE IF EXISTS public.chat_attachments
  DROP COLUMN IF EXISTS purge_ready;

DROP TABLE IF EXISTS public.chat_attachment_receipts;
DROP TABLE IF EXISTS public.chat_attachment_targets;
DROP TABLE IF EXISTS public.chat_user_devices;

COMMIT;
