BEGIN;

CREATE TABLE IF NOT EXISTS public.chat_attachment_quarantine (
  file_id uuid PRIMARY KEY,
  bucket_id text NOT NULL,
  file_name text,
  reason_code text NOT NULL,
  discovered_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolution_note text
);

DO $do$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'storage.files is absent; ownership migration skipped';
    RETURN;
  END IF;

  BEGIN
    EXECUTE 'SET LOCAL ROLE nhost_storage_admin';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'cannot assume nhost_storage_admin for storage hardening';
  END;

  EXECUTE 'ALTER TABLE storage.files
    ADD COLUMN IF NOT EXISTS account_id uuid,
    ADD COLUMN IF NOT EXISTS conversation_id uuid,
    ADD COLUMN IF NOT EXISTS attachment_message_id uuid,
    ADD COLUMN IF NOT EXISTS security_state text NOT NULL DEFAULT ''unclassified''';

  EXECUTE 'ALTER TABLE storage.files
    DROP CONSTRAINT IF EXISTS storage_files_security_state_check,
    ADD CONSTRAINT storage_files_security_state_check
      CHECK (security_state IN (''unclassified'', ''active'', ''quarantined''))';

  EXECUTE $sql$
    UPDATE storage.files sf
       SET account_id = c.account_id,
           conversation_id = m.conversation_id,
           attachment_message_id = a.message_id,
           security_state = 'active'
      FROM public.chat_attachments a
      JOIN public.chat_messages m ON m.id = a.message_id
      JOIN public.chat_conversations c ON c.id = m.conversation_id
     WHERE sf.bucket_id IN ('chat-images', 'chat-attachments')
       AND (a.path = sf.id::text OR a.path = sf.name)
       AND sf.account_id IS NULL
  $sql$;

  EXECUTE $sql$
    UPDATE storage.files sf
       SET account_id = c.account_id,
           conversation_id = c.id,
           attachment_message_id = CASE
             WHEN (sf.metadata->>'message_id') ~*
                  '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
             THEN (sf.metadata->>'message_id')::uuid
             ELSE sf.attachment_message_id
           END,
           security_state = CASE
             WHEN EXISTS (
               SELECT 1 FROM public.chat_messages m
                WHERE m.id = CASE
                  WHEN (sf.metadata->>'message_id') ~*
                       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  THEN (sf.metadata->>'message_id')::uuid
                  ELSE NULL
                END
                  AND m.conversation_id = c.id
             ) THEN 'active'
             ELSE 'quarantined'
           END
      FROM public.chat_conversations c
     WHERE sf.bucket_id IN ('chat-images', 'chat-attachments')
       AND sf.account_id IS NULL
       AND (sf.metadata->>'conversation_id') ~*
           '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       AND c.id = (sf.metadata->>'conversation_id')::uuid
  $sql$;

  EXECUTE $sql$
    UPDATE storage.files
       SET security_state = 'quarantined'
     WHERE bucket_id IN ('chat-images', 'chat-attachments')
       AND (account_id IS NULL OR conversation_id IS NULL OR attachment_message_id IS NULL)
  $sql$;

  EXECUTE $sql$
    INSERT INTO public.chat_attachment_quarantine(file_id, bucket_id, file_name, reason_code)
    SELECT id, bucket_id, name, 'ownership_unresolved'
      FROM storage.files
     WHERE bucket_id IN ('chat-images', 'chat-attachments')
       AND security_state = 'quarantined'
    ON CONFLICT (file_id) DO NOTHING
  $sql$;

  EXECUTE 'CREATE INDEX IF NOT EXISTS idx_storage_files_chat_scope
    ON storage.files(account_id, conversation_id, security_state)
    WHERE bucket_id IN (''chat-images'', ''chat-attachments'')';

  EXECUTE 'DROP POLICY IF EXISTS chat_images_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_images_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_images_files_update ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_images_files_delete ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_update ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_files_select_strict ON storage.files';

  -- Deliberately create no client RLS policy for chat buckets. The Functions
  -- use the admin secret only after checking active membership and ownership.
END
$do$;

COMMIT;
