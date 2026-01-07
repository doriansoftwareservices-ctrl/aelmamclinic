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

  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files';

  EXECUTE 'ALTER TABLE storage.files DISABLE ROW LEVEL SECURITY';
END
$do$;

COMMIT;