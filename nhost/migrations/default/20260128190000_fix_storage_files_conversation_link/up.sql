DO $$
DECLARE
  owner_name text;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files conversation FK: table missing';
    RETURN;
  END IF;

  SELECT r.rolname
    INTO owner_name
  FROM pg_class c
  JOIN pg_roles r ON r.oid = c.relowner
  WHERE c.oid = 'storage.files'::regclass;

  IF owner_name IS DISTINCT FROM current_user THEN
    RAISE NOTICE 'skip storage.files conversation FK: not owner (current_user=%, owner=%)', current_user, owner_name;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'storage'
      AND table_name = 'files'
      AND column_name = 'conversation_id'
  ) THEN
    RAISE NOTICE 'skip storage.files conversation FK: conversation_id column missing';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname='storage_files_conversation_id_fkey'
      AND conrelid='storage.files'::regclass
  ) THEN
    ALTER TABLE storage.files
      ADD CONSTRAINT storage_files_conversation_id_fkey
      FOREIGN KEY (conversation_id)
      REFERENCES public.chat_conversations(id)
      ON DELETE SET NULL;
  END IF;
END $$;
