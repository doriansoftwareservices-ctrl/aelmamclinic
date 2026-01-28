BEGIN;

-- Ensure FK exists for metadata relationship storage.files.chat_conversation
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'storage_files_conversation_id_fkey'
      AND conrelid = 'storage.files'::regclass
  ) THEN
    ALTER TABLE storage.files
      ADD CONSTRAINT storage_files_conversation_id_fkey
      FOREIGN KEY (conversation_id)
      REFERENCES public.chat_conversations(id)
      ON DELETE SET NULL
      DEFERRABLE INITIALLY IMMEDIATE;
  END IF;
END $$;

COMMIT;
