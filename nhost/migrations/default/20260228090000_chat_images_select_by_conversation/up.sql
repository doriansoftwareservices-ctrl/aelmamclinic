BEGIN;

DO $do$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files policies: table missing';
    RETURN;
  END IF;

  BEGIN
    EXECUTE 'SET LOCAL ROLE nhost_storage_admin';
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'skip storage.files policies: cannot SET ROLE (current_user=%)',
      current_user;
    RETURN;
  END;

  EXECUTE 'ALTER TABLE storage.files ENABLE ROW LEVEL SECURITY';

  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_images_files_select ON storage.files;
    CREATE POLICY chat_images_files_select
    ON storage.files
    FOR SELECT
    TO PUBLIC
    USING (
      bucket_id = 'chat-images'
      AND (
        -- allow by attachment linkage
        EXISTS (
          SELECT 1
          FROM public.chat_attachments a
          JOIN public.chat_messages m ON m.id = a.message_id
          JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND a.bucket = 'chat-images'
            AND (
              a.path = storage.files.id::text
              OR a.path = storage.files.name
            )
        )
        -- allow by conversation_id on storage.files (fast path)
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND p.conversation_id = storage.files.conversation_id
        )
      )
    );
  $sql$;
END
$do$;

COMMIT;
