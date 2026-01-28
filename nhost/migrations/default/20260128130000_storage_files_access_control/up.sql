BEGIN;

-- 1) Add linkage columns for chat attachments
ALTER TABLE storage.files ADD COLUMN IF NOT EXISTS conversation_id uuid;
ALTER TABLE storage.files ADD COLUMN IF NOT EXISTS message_id uuid;

-- 2) Parse IDs from object name for chat attachments
-- Expected name format: attachments/<conversation_uuid>/<message_uuid>/...
CREATE OR REPLACE FUNCTION storage.set_chat_attachment_ids()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_conv text;
  v_msg  text;
BEGIN
  IF NEW.bucket_id = 'chat-attachments' THEN
    v_conv := split_part(NEW.name, '/', 2);
    v_msg  := split_part(NEW.name, '/', 3);

    NEW.conversation_id := NULL;
    NEW.message_id := NULL;

    IF v_conv ~* '^[0-9a-f-]{36}$' THEN
      NEW.conversation_id := v_conv::uuid;
    END IF;
    IF v_msg ~* '^[0-9a-f-]{36}$' THEN
      NEW.message_id := v_msg::uuid;
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS set_chat_attachment_ids ON storage.files;
CREATE TRIGGER set_chat_attachment_ids
BEFORE INSERT OR UPDATE OF name, bucket_id
ON storage.files
FOR EACH ROW
EXECUTE FUNCTION storage.set_chat_attachment_ids();

-- Backfill existing rows
UPDATE storage.files
SET
  conversation_id = CASE
    WHEN bucket_id='chat-attachments'
     AND split_part(name,'/',2) ~* '^[0-9a-f-]{36}$'
    THEN split_part(name,'/',2)::uuid
    ELSE conversation_id
  END,
  message_id = CASE
    WHEN bucket_id='chat-attachments'
     AND split_part(name,'/',3) ~* '^[0-9a-f-]{36}$'
    THEN split_part(name,'/',3)::uuid
    ELSE message_id
  END
WHERE bucket_id='chat-attachments'
  AND (conversation_id IS NULL OR message_id IS NULL);

-- 3) Disable RLS on storage.files (let Hasura permissions handle access)
ALTER TABLE storage.files DISABLE ROW LEVEL SECURITY;
ALTER TABLE storage.files NO FORCE ROW LEVEL SECURITY;

-- Drop legacy policies (safe cleanup)
DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files;
DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files;
DROP POLICY IF EXISTS chat_attachments_files_update ON storage.files;
DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files;

DROP POLICY IF EXISTS subscription_proofs_select ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_update ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files;

COMMIT;
