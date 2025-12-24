-- Ensure chat tables exist before chat policies/views/triggers
-- Needed because several migrations reference public.chat_messages/views.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
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

CREATE TABLE IF NOT EXISTS public.chat_participants (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  email text,
  nickname text,
  role text,
  joined_at timestamptz,
  muted boolean NOT NULL DEFAULT false,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

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

CREATE TABLE IF NOT EXISTS public.chat_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  bucket text NOT NULL DEFAULT 'chat-attachments',
  path text NOT NULL,
  mime_type text,
  size_bytes integer,
  width integer,
  height integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id text,
  local_id bigint,
  FOREIGN KEY (message_id)
    REFERENCES public.chat_messages(id) ON DELETE CASCADE
);

