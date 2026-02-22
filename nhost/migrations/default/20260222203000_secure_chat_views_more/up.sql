DO $$
BEGIN
  BEGIN
    EXECUTE 'ALTER VIEW IF EXISTS public.v_chat_conversations_for_me SET (security_invoker = true)';
  EXCEPTION WHEN others THEN
    -- PG < 15 لا يدعم security_invoker للـ VIEWs، تجاهل الخطأ.
  END;

  BEGIN
    EXECUTE 'ALTER VIEW IF EXISTS public.v_chat_reads_for_me SET (security_invoker = true)';
  EXCEPTION WHEN others THEN
    -- تجاهل في حال عدم الدعم.
  END;

  BEGIN
    EXECUTE 'ALTER VIEW IF EXISTS public.v_chat_messages_with_attachments SET (security_invoker = true)';
  EXCEPTION WHEN others THEN
    -- تجاهل في حال عدم الدعم.
  END;
END $$;
