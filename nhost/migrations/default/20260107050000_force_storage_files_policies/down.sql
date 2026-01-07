BEGIN;

SET ROLE nhost_storage_admin;

DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files;
DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_select ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files;

ALTER TABLE storage.files DISABLE ROW LEVEL SECURITY;

RESET ROLE;

COMMIT;
