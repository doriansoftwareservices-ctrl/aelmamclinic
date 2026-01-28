BEGIN;

DROP TRIGGER IF EXISTS set_chat_attachment_ids ON storage.files;
DROP FUNCTION IF EXISTS storage.set_chat_attachment_ids();

ALTER TABLE storage.files DROP COLUMN IF EXISTS message_id;
ALTER TABLE storage.files DROP COLUMN IF EXISTS conversation_id;

COMMIT;
