BEGIN;

-- 1) Add column if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='storage'
      AND table_name='files'
      AND column_name='conversation_id'
  ) THEN
    ALTER TABLE storage.files
      ADD COLUMN conversation_id uuid NULL;
  END IF;
END $$;

-- 2) Add FK if missing
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
      ON DELETE SET NULL;
  END IF;
END $$;

-- 3) Helpful index
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname='storage'
      AND tablename='files'
      AND indexname='storage_files_conversation_id_idx'
  ) THEN
    CREATE INDEX storage_files_conversation_id_idx
      ON storage.files(conversation_id);
  END IF;
END $$;

COMMIT;
