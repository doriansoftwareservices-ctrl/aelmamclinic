BEGIN;

-- profiles
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  role text NOT NULL DEFAULT 'employee',
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS profiles_account_idx ON public.profiles(account_id);

-- chat_conversations
CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  title text,
  is_group boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_msg_at timestamptz,
  last_msg_snippet text,
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS chat_conversations_account_idx ON public.chat_conversations(account_id);
CREATE INDEX IF NOT EXISTS chat_conversations_last_msg_at_idx ON public.chat_conversations(last_msg_at);

-- chat_participants
CREATE TABLE IF NOT EXISTS public.chat_participants (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  email text,
  nickname text,
  role text,
  joined_at timestamptz,
  muted boolean NOT NULL DEFAULT false,
  display_name text,
  pinned boolean NOT NULL DEFAULT false,
  archived boolean NOT NULL DEFAULT false,
  blocked boolean NOT NULL DEFAULT false,
  last_read_at timestamptz,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);
CREATE INDEX IF NOT EXISTS chat_participants_account_idx ON public.chat_participants(account_id);

-- chat_messages
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  sender_uid uuid NOT NULL,
  sender_email text,
  kind text NOT NULL DEFAULT 'text',
  body text,
  text text,
  attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  mentions jsonb NOT NULL DEFAULT '[]'::jsonb,
  reply_to_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  reply_to_id text,
  reply_to_snippet text,
  patient_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  edited boolean NOT NULL DEFAULT false,
  edited_at timestamptz,
  deleted boolean NOT NULL DEFAULT false,
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id text,
  local_id bigint,
  FOREIGN KEY (account_id, sender_uid)
    REFERENCES public.account_users(account_id, user_uid)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_messages_device_local
  ON public.chat_messages (account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

-- chat_reads
CREATE TABLE IF NOT EXISTS public.chat_reads (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  last_read_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  last_read_at timestamptz,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

-- chat_attachments FK (keep only if table exists)
DO $$
BEGIN
  IF to_regclass('public.chat_attachments') IS NOT NULL
     AND to_regclass('public.chat_messages') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'chat_attachments_message_id_fkey'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_attachments
               ADD CONSTRAINT chat_attachments_message_id_fkey
               FOREIGN KEY (message_id) REFERENCES public.chat_messages(id)
               ON DELETE CASCADE';
    END IF;
  END IF;
END $$;

COMMIT;
