DO $do$
DECLARE
  pub_oid oid := (SELECT oid FROM pg_publication WHERE pubname = 'supabase_realtime');
BEGIN
  IF pub_oid IS NULL THEN
    RAISE NOTICE 'skip publication supabase_realtime: not present on Nhost';
    RETURN;
  END IF;

  -- add only if tables exist AND not already in publication
  PERFORM 1 FROM pg_publication_rel pr JOIN pg_class t ON t.oid = pr.prrelid
    WHERE pr.prpubid = pub_oid AND t.relname = 'chat_messages';
  IF NOT FOUND AND to_regclass('public.chat_messages') IS NOT NULL THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages';
  END IF;

  PERFORM 1 FROM pg_publication_rel pr JOIN pg_class t ON t.oid = pr.prrelid
    WHERE pr.prpubid = pub_oid AND t.relname = 'chat_conversations';
  IF NOT FOUND AND to_regclass('public.chat_conversations') IS NOT NULL THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_conversations';
  END IF;

  PERFORM 1 FROM pg_publication_rel pr JOIN pg_class t ON t.oid = pr.prrelid
    WHERE pr.prpubid = pub_oid AND t.relname = 'chat_participants';
  IF NOT FOUND AND to_regclass('public.chat_participants') IS NOT NULL THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_participants';
  END IF;

  PERFORM 1 FROM pg_publication_rel pr JOIN pg_class t ON t.oid = pr.prrelid
    WHERE pr.prpubid = pub_oid AND t.relname = 'chat_reads';
  IF NOT FOUND AND to_regclass('public.chat_reads') IS NOT NULL THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_reads';
  END IF;
END
$do$;
