BEGIN;

DO $$
DECLARE
  owner_name text;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;

  SELECT r.rolname INTO owner_name
  FROM pg_class c
  JOIN pg_roles r ON r.oid = c.relowner
  WHERE c.oid = 'storage.files'::regclass;

  IF owner_name IS DISTINCT FROM current_user THEN
    RAISE NOTICE 'skip storage.files policies: not owner (current_user=%, owner=%)', current_user, owner_name;
    RETURN;
  END IF;

  DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
  CREATE POLICY chat_attachments_files_insert
    ON storage.files
    FOR INSERT
    TO public
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND (
        uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
        OR (
          uploaded_by_user_id IS NULL
          AND nullif(public.request_uid_text(), '') IS NOT NULL
        )
      )
    );

  DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
  CREATE POLICY subscription_proofs_insert
    ON storage.files
    FOR INSERT
    TO public
    WITH CHECK (
      bucket_id = 'subscription-proofs'
    );
END;
$$;

COMMIT;
