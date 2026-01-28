BEGIN;

ALTER TABLE storage.files
  DROP CONSTRAINT IF EXISTS storage_files_conversation_id_fkey;

COMMIT;
