-- Stage 4: Storage RLS for chat attachments on Nhost storage.files.

DO $do$
DECLARE
  owner_name text;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files policies: table missing';
    RETURN;
  END IF;

  SELECT r.rolname
    INTO owner_name
  FROM pg_class c
  JOIN pg_roles r ON r.oid = c.relowner
  WHERE c.oid = 'storage.files'::regclass;

  IF owner_name IS DISTINCT FROM current_user THEN
    RAISE NOTICE 'skip storage.files policies: not owner (current_user=%, owner=%)', current_user, owner_name;
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE storage.files ENABLE ROW LEVEL SECURITY';

  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files;
    CREATE POLICY chat_attachments_files_select
    ON storage.files
    FOR SELECT
    TO PUBLIC
    USING (
      bucket_id = 'chat-attachments'
      AND (
        public.fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.chat_attachments a
          JOIN public.chat_messages m ON m.id = a.message_id
          JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND a.bucket = 'chat-attachments'
            AND (
              a.path = storage.files.id::text
              OR a.path = storage.files.name
            )
        )
      )
    );
  $sql$;

  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
    CREATE POLICY chat_attachments_files_insert
    ON storage.files
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
    );
  $sql$;

  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files;
    CREATE POLICY chat_attachments_files_delete
    ON storage.files
    FOR DELETE
    TO PUBLIC
    USING (
      bucket_id = 'chat-attachments'
      AND (
        uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
        OR public.fn_is_super_admin() = true
      )
    );
  $sql$;
END
$do$;
