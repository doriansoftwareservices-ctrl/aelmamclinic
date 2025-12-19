alter table if exists chat_messages
  add column if not exists account_id text,
  add column if not exists device_id text,
  add column if not exists local_id  bigint;
-- تقدر تضيف فهرس اختياريًا لتحسين الاستعلامات لو احتجت:
-- create index if not exists chat_messages_idx_account on chat_messages(account_id);;
