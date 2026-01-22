BEGIN;

DO $$
BEGIN
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    ALTER TABLE public.chat_messages
      DROP CONSTRAINT IF EXISTS chat_messages_conversation_client_msg_id_key;
    ALTER TABLE public.chat_messages
      DROP COLUMN IF EXISTS client_msg_id;
  END IF;
END $$;

DROP INDEX IF EXISTS public.idx_chat_messages_client_msg_id;

COMMIT;
