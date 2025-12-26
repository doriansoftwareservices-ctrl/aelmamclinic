-- Revert Stage 4 storage.files policies for chat attachments.

DO $do$
DECLARE
  owner_name text;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;

  SELECT r.rolname
    INTO owner_name
  FROM pg_class c
  JOIN pg_roles r ON r.oid = c.relowner
  WHERE c.oid = 'storage.files'::regclass;

  IF owner_name IS DISTINCT FROM current_user THEN
    RETURN;
  END IF;

  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files';
END
$do$;
