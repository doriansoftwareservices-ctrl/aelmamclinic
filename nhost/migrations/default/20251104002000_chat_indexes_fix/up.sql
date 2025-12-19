-- Improve chat query performance for participants/messages lookups.

create index if not exists idx_chat_participants_user_uid
  on public.chat_participants (user_uid);

create index if not exists idx_chat_messages_conversation_created_at
  on public.chat_messages (conversation_id, created_at desc);

create index if not exists idx_account_users_email_lower
  on public.account_users ((lower(email)));
