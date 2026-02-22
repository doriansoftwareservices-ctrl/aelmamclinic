ALTER VIEW IF EXISTS public.v_chat_conversations_for_me SET (security_invoker = true);
ALTER VIEW IF EXISTS public.v_chat_reads_for_me SET (security_invoker = true);
ALTER VIEW IF EXISTS public.v_chat_messages_with_attachments SET (security_invoker = true);
