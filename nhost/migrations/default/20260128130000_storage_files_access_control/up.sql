-- Compatibility migration for older deployments that used custom linkage
-- columns on Nhost's managed storage.files table. New Nhost Cloud projects do
-- not allow the migration role to alter that internal table, so this migration
-- is intentionally skipped unless it is executed by the table owner.

DO $do$
DECLARE
  owner_name text;
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files access control: table missing';
    RETURN;
  END IF;

  SELECT r.rolname
    INTO owner_name
  FROM pg_class c
  JOIN pg_roles r ON r.oid = c.relowner
  WHERE c.oid = 'storage.files'::regclass;

  IF owner_name IS DISTINCT FROM current_user THEN
    RAISE NOTICE 'skip storage.files access control: not owner (current_user=%, owner=%)', current_user, owner_name;
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE storage.files ADD COLUMN IF NOT EXISTS conversation_id uuid';
  EXECUTE 'ALTER TABLE storage.files ADD COLUMN IF NOT EXISTS message_id uuid';

  EXECUTE $sql$
    CREATE OR REPLACE FUNCTION storage.set_chat_attachment_ids()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $fn$
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
    END;
    $fn$;
  $sql$;

  EXECUTE 'DROP TRIGGER IF EXISTS set_chat_attachment_ids ON storage.files';
  EXECUTE 'CREATE TRIGGER set_chat_attachment_ids BEFORE INSERT OR UPDATE OF name, bucket_id ON storage.files FOR EACH ROW EXECUTE FUNCTION storage.set_chat_attachment_ids()';

  EXECUTE $sql$
    UPDATE storage.files
    SET
      conversation_id = CASE
        WHEN bucket_id = 'chat-attachments'
         AND split_part(name, '/', 2) ~* '^[0-9a-f-]{36}$'
        THEN split_part(name, '/', 2)::uuid
        ELSE conversation_id
      END,
      message_id = CASE
        WHEN bucket_id = 'chat-attachments'
         AND split_part(name, '/', 3) ~* '^[0-9a-f-]{36}$'
        THEN split_part(name, '/', 3)::uuid
        ELSE message_id
      END
    WHERE bucket_id = 'chat-attachments'
      AND (conversation_id IS NULL OR message_id IS NULL)
  $sql$;

  EXECUTE 'ALTER TABLE storage.files DISABLE ROW LEVEL SECURITY';
  EXECUTE 'ALTER TABLE storage.files NO FORCE ROW LEVEL SECURITY';

  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_update ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_update ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files';
END
$do$;
