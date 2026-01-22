BEGIN;

DO $$
BEGIN
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    ALTER TABLE public.chat_messages
      ADD COLUMN IF NOT EXISTS client_msg_id text;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'chat_messages_conversation_client_msg_id_key'
    ) THEN
      ALTER TABLE public.chat_messages
        ADD CONSTRAINT chat_messages_conversation_client_msg_id_key
        UNIQUE (conversation_id, client_msg_id);
    END IF;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_chat_messages_client_msg_id
  ON public.chat_messages(client_msg_id);

COMMIT;
