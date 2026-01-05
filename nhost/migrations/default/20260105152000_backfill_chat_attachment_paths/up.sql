BEGIN;

-- Normalize chat attachment paths to storage.files.name when path stored file_id.
DO $$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.chat_attachments a
     SET path = f.name
    FROM storage.files f
   WHERE a.bucket = 'chat-attachments'
     AND a.path = f.id::text
     AND f.bucket_id = 'chat-attachments'
     AND f.name IS NOT NULL;
END$$;

COMMIT;
