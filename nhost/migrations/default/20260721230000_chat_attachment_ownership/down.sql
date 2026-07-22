BEGIN;

-- Forward-fix rollback: keep ownership columns and quarantine evidence. Removing
-- them would make previously classified medical attachments ambiguous again.
DO $do$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE 'SET LOCAL ROLE nhost_storage_admin';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'cannot assume nhost_storage_admin for storage rollback';
  END;
  EXECUTE 'DROP POLICY IF EXISTS chat_files_select_strict ON storage.files';
  EXECUTE 'ALTER TABLE storage.files
    DROP CONSTRAINT IF EXISTS storage_files_security_state_check';
END
$do$;

COMMIT;
