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
              COALESCE(
                CASE
                  WHEN split_part(storage.files.name, '/', 2) ~* '^[0-9a-f-]{36}$'
                    THEN split_part(storage.files.name, '/', 2)::uuid
                  ELSE NULL
                END,
                CASE
                  WHEN (storage.files.metadata->>'conversation_id') ~* '^[0-9a-f-]{36}$'
                    THEN (storage.files.metadata->>'conversation_id')::uuid
                  ELSE NULL
                END
              )
            )
        )
      )
    );
  $sql$;

  -- INSERT: allow participants to upload into chat-attachments bucket
  -- NOTE: uploaded_by_user_id can be null at INSERT time in Nhost Storage,
  -- so do not require it here.
  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
    CREATE POLICY chat_attachments_files_insert
    ON storage.files
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND (
        public.fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND coalesce(p.is_deleted, false) = false
            AND p.conversation_id = (
              COALESCE(
                CASE
                  WHEN split_part(storage.files.name, '/', 2) ~* '^[0-9a-f-]{36}$'
                    THEN split_part(storage.files.name, '/', 2)::uuid
                  ELSE NULL
                END,
                CASE
                  WHEN (storage.files.metadata->>'conversation_id') ~* '^[0-9a-f-]{36}$'
                    THEN (storage.files.metadata->>'conversation_id')::uuid
                  ELSE NULL
                END
              )
            )
        )
      )
    );
  $sql$;

  -- UPDATE: allow storage to finalize upload metadata for participants
  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_attachments_files_update ON storage.files;
    CREATE POLICY chat_attachments_files_update
    ON storage.files
    FOR UPDATE
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
              COALESCE(
                CASE
                  WHEN split_part(storage.files.name, '/', 2) ~* '^[0-9a-f-]{36}$'
                    THEN split_part(storage.files.name, '/', 2)::uuid
                  ELSE NULL
                END,
                CASE
                  WHEN (storage.files.metadata->>'conversation_id') ~* '^[0-9a-f-]{36}$'
                    THEN (storage.files.metadata->>'conversation_id')::uuid
                  ELSE NULL
                END
              )
            )
        )
      )
    )
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND (
        public.fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND coalesce(p.is_deleted, false) = false
            AND p.conversation_id = (
              COALESCE(
                CASE
                  WHEN split_part(storage.files.name, '/', 2) ~* '^[0-9a-f-]{36}$'
                    THEN split_part(storage.files.name, '/', 2)::uuid
                  ELSE NULL
                END,
                CASE
                  WHEN (storage.files.metadata->>'conversation_id') ~* '^[0-9a-f-]{36}$'
                    THEN (storage.files.metadata->>'conversation_id')::uuid
                  ELSE NULL
                END
              )
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
