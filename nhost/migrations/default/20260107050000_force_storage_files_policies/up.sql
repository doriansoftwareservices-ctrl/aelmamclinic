BEGIN;

DO $do$
DECLARE
  has_storage_role boolean := false;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files policies: table missing';
    RETURN;
  END IF;

  BEGIN
    has_storage_role := pg_has_role(current_user, 'nhost_storage_admin', 'member');
  EXCEPTION WHEN others THEN
    has_storage_role := false;
  END;

  IF NOT has_storage_role THEN
    BEGIN
      EXECUTE format('GRANT nhost_storage_admin TO %I', current_user);
      has_storage_role := pg_has_role(current_user, 'nhost_storage_admin', 'member');
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'skip storage.files policies: cannot GRANT role to %',
        current_user;
    END;
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

  EXECUTE $sql$
    DROP POLICY IF EXISTS subscription_proofs_select ON storage.files;
    CREATE POLICY subscription_proofs_select
    ON storage.files
    FOR SELECT
    TO PUBLIC
    USING (
      bucket_id = 'subscription-proofs'
      AND (
        uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
        OR public.fn_is_super_admin() = true
      )
    );
  $sql$;

  EXECUTE $sql$
    DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
    CREATE POLICY subscription_proofs_insert
    ON storage.files
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'subscription-proofs'
      AND uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
    );
  $sql$;

  EXECUTE $sql$
    DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files;
    CREATE POLICY subscription_proofs_delete
    ON storage.files
    FOR DELETE
    TO PUBLIC
    USING (
      bucket_id = 'subscription-proofs'
      AND (
        uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
        OR public.fn_is_super_admin() = true
      )
    );
  $sql$;
END
$do$;

COMMIT;
