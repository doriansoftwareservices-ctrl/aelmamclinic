do $$
declare
  pub_oid oid := (select oid from pg_publication where pubname = 'supabase_realtime');
begin
  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_messages';
  if not found then
    execute 'alter publication supabase_realtime add table chat_messages';
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_conversations';
  if not found then
    execute 'alter publication supabase_realtime add table chat_conversations';
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_participants';
  if not found then
    execute 'alter publication supabase_realtime add table chat_participants';
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_reads';
  if not found then
    execute 'alter publication supabase_realtime add table chat_reads';
  end if;
end $$;
