DO $do$
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

  EXECUTE 'DROP TRIGGER IF EXISTS set_chat_attachment_ids ON storage.files';
  EXECUTE 'DROP FUNCTION IF EXISTS storage.set_chat_attachment_ids()';
  EXECUTE 'ALTER TABLE storage.files DROP COLUMN IF EXISTS message_id';
  EXECUTE 'ALTER TABLE storage.files DROP COLUMN IF EXISTS conversation_id';
END
$do$;
