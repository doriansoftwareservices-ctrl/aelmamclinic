BEGIN;

DROP INDEX IF EXISTS storage.storage_files_conversation_id_idx;

ALTER TABLE storage.files
  DROP CONSTRAINT IF EXISTS storage_files_conversation_id_fkey;

-- لو تحب “رجوع كامل” احذف العمود أيضًا:
ALTER TABLE storage.files
  DROP COLUMN IF EXISTS conversation_id;

COMMIT;
