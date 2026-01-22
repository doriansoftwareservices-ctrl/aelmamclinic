-- Ensure storage.files policies allow chat attachment uploads/downloads
-- for conversation participants (path: attachments/<conversationId>/<messageId>/...).

DO $do$
DECLARE
  owner_name text;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files chat policies: table missing';
    RETURN;
  END IF;

  SELECT r.rolname
    INTO owner_name
  FROM pg_class c
  JOIN pg_roles r ON r.oid = c.relowner
  WHERE c.oid = 'storage.files'::regclass;

  IF owner_name IS DISTINCT FROM current_user THEN
    RAISE NOTICE 'skip storage.files chat policies: not owner (current_user=%, owner=%)', current_user, owner_name;
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE storage.files ENABLE ROW LEVEL SECURITY';

  -- SELECT: allow participants (or superadmin) to read chat attachments
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
          FROM public.chat_participants p
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND coalesce(p.is_deleted, false) = false
            AND p.conversation_id = (
              CASE
                WHEN split_part(storage.files.name, '/', 2) ~* '^[0-9a-f-]{36}$'
                  THEN split_part(storage.files.name, '/', 2)::uuid
                ELSE NULL
              END
            )
        )
      )
    );
  $sql$;

  -- INSERT: allow participants to upload into chat-attachments bucket
  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
    CREATE POLICY chat_attachments_files_insert
    ON storage.files
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
      AND (
        public.fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND coalesce(p.is_deleted, false) = false
            AND p.conversation_id = (
              CASE
                WHEN split_part(storage.files.name, '/', 2) ~* '^[0-9a-f-]{36}$'
                  THEN split_part(storage.files.name, '/', 2)::uuid
                ELSE NULL
              END
            )
        )
      )
    );
  $sql$;

  -- DELETE: uploader or superadmin
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
