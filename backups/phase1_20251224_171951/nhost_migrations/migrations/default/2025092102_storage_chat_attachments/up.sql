-- 2025092102_storage_chat_attachments.sql
-- Nhost note: storage schema may differ from Supabase (storage.objects may be absent).
-- This migration becomes a no-op when storage.objects doesn't exist, so migrations can continue.

CREATE OR REPLACE FUNCTION public.chat_conversation_id_from_path(_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN regexp_match(
             _name,
             '^attachments/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/'
           ) IS NULL
           THEN NULL
           ELSE ((regexp_match(
             _name,
             '^attachments/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/'
           ))[1])::uuid
         END;
$$;

DO $policies$
BEGIN
  -- Guard: if Nhost storage doesn't have storage.objects, skip this migration
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage.objects not found; skipping chat-attachments storage policies';
    RETURN;
  END IF;

  -- Enable RLS if possible
  BEGIN
    EXECUTE 'alter table storage.objects enable row level security';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- Try to impersonate storage owner role (may fail on some managed environments)
  BEGIN
    EXECUTE 'set local role supabase_storage_admin';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RETURN;
    WHEN undefined_object THEN
      -- role supabase_storage_admin غير موجود في Nhost
      RETURN;
    WHEN invalid_authorization_specification THEN
      RETURN;
    WHEN invalid_role_specification THEN
      RETURN;
    WHEN others THEN
      RETURN;
  END;

  -- READ
  EXECUTE 'drop policy if exists "chat-attachments read for participants" on storage.objects';
  EXECUTE $$
    create policy "chat-attachments read for participants"
    on storage.objects
    for select
    to public
    using (
      bucket_id = 'chat-attachments'
      and exists (
        select 1
        from public.chat_participants p
        where p.conversation_id = public.chat_conversation_id_from_path(name)
          and p.user_uid = public.request_uid_text()::uuid
      )
    );
  $$;

  -- INSERT
  EXECUTE 'drop policy if exists "chat-attachments insert for participants" on storage.objects';
  EXECUTE $$
    create policy "chat-attachments insert for participants"
    on storage.objects
    for insert
    to public
    with check (
      bucket_id = 'chat-attachments'
      and exists (
        select 1
        from public.chat_participants p
        where p.conversation_id = public.chat_conversation_id_from_path(name)
          and p.user_uid = public.request_uid_text()::uuid
      )
    );
  $$;

  -- DELETE
  EXECUTE 'drop policy if exists "chat-attachments delete for participants" on storage.objects';
  EXECUTE $$
    create policy "chat-attachments delete for participants"
    on storage.objects
    for delete
    to public
    using (
      bucket_id = 'chat-attachments'
      and exists (
        select 1
        from public.chat_participants p
        where p.conversation_id = public.chat_conversation_id_from_path(name)
          and p.user_uid = public.request_uid_text()::uuid
      )
    );
  $$;

  EXECUTE 'reset role';
END
$policies$;
