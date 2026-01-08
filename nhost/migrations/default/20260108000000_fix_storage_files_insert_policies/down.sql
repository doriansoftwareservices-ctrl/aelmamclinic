BEGIN;

DO $$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;

  DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
  CREATE POLICY chat_attachments_files_insert
    ON storage.files
    FOR INSERT
    TO public
    WITH CHECK (
      bucket_id = 'chat-attachments'
      AND uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
    );

  DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
  CREATE POLICY subscription_proofs_insert
    ON storage.files
    FOR INSERT
    TO public
    WITH CHECK (
      bucket_id = 'subscription-proofs'
      AND uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
    );
END;
$$;

COMMIT;
