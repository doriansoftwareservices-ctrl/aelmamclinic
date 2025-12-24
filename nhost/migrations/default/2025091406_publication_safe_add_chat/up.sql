do $$
declare
  pub_oid oid := (select oid from pg_publication where pubname = 'supabase_realtime');
begin
  if pub_oid is null then
    raise notice 'skip publication supabase_realtime: not present';
    return;
  end if;

  if to_regclass('public.chat_messages') is null
     and to_regclass('public.chat_conversations') is null
     and to_regclass('public.chat_participants') is null
     and to_regclass('public.chat_reads') is null then
    raise notice 'skip publication supabase_realtime: chat tables not present';
    return;
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_messages';
  if not found and to_regclass('public.chat_messages') is not null then
    execute 'alter publication supabase_realtime add table chat_messages';
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_conversations';
  if not found and to_regclass('public.chat_conversations') is not null then
    execute 'alter publication supabase_realtime add table chat_conversations';
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_participants';
  if not found and to_regclass('public.chat_participants') is not null then
    execute 'alter publication supabase_realtime add table chat_participants';
  end if;

  perform 1 from pg_publication_rel pr
   join pg_class t on t.oid = pr.prrelid
   where pr.prpubid = pub_oid and t.relname = 'chat_reads';
  if not found and to_regclass('public.chat_reads') is not null then
    execute 'alter publication supabase_realtime add table chat_reads';
  end if;
end $$;
