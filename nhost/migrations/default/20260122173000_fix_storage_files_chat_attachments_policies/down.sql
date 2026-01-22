-- Revert chat attachment policies on storage.files

DO $do$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;

  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files';
END
$do$;
