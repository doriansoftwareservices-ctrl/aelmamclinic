DO $$
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

  EXECUTE 'DROP INDEX IF EXISTS storage.storage_files_conversation_id_idx';
  EXECUTE 'ALTER TABLE storage.files DROP CONSTRAINT IF EXISTS storage_files_conversation_id_fkey';
  EXECUTE 'ALTER TABLE storage.files DROP COLUMN IF EXISTS conversation_id';
END $$;
