do $$
begin
  begin
    alter publication supabase_realtime add table
      chat_messages,
      chat_conversations,
      chat_participants,
      chat_reads;
  exception
    when duplicate_object then
      -- الجداول مضافة من قبل؛ تجاهل.
      null;
  end;
end$$;
