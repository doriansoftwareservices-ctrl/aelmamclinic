-- إزالة الـ FKs المكرّرة التي تربك PostgREST عند الـ embed
do $$
begin
  -- chat_participants → chat_conversations
  if exists (select 1 from pg_constraint where conname = 'chat_participants_conversation_id_fkey')
     and exists (select 1 from pg_constraint where conname = 'fk_chat_participants_conversation') then
    alter table public.chat_participants
      drop constraint fk_chat_participants_conversation;
  end if;

  -- احتياطًا: chat_messages → chat_conversations (إن كانت مكررة كذلك)
  if exists (select 1 from pg_constraint where conname = 'chat_messages_conversation_id_fkey')
     and exists (select 1 from pg_constraint where conname = 'fk_chat_messages_conversation') then
    alter table public.chat_messages
      drop constraint fk_chat_messages_conversation;
  end if;
end$$;
