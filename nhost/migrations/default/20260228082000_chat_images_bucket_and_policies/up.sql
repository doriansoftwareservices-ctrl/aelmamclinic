BEGIN;

-- 1) Ensure chat-images bucket exists
INSERT INTO storage.buckets (id)
VALUES ('chat-images')
ON CONFLICT (id) DO NOTHING;

-- 2) storage.files changes + policies (requires owner)
DO $do$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RAISE NOTICE 'skip storage.files policies: table missing';
    RETURN;
  END IF;

  BEGIN
    EXECUTE 'SET LOCAL ROLE nhost_storage_admin';
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'skip storage.files policies: cannot SET ROLE (current_user=%)',
      current_user;
    RETURN;
  END;

  -- Ensure linkage columns exist
  EXECUTE 'ALTER TABLE storage.files ADD COLUMN IF NOT EXISTS conversation_id uuid';
  EXECUTE 'ALTER TABLE storage.files ADD COLUMN IF NOT EXISTS message_id uuid';

  -- Parse IDs from object name for chat attachments (chat-attachments + chat-images)
  -- Expected name format: attachments/<conversation_uuid>/<message_uuid>/...
  EXECUTE $fn$
    CREATE OR REPLACE FUNCTION storage.set_chat_attachment_ids()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      v_conv text;
      v_msg  text;
    BEGIN
      IF NEW.bucket_id IN ('chat-attachments','chat-images') THEN
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
  $fn$;

  EXECUTE 'DROP TRIGGER IF EXISTS set_chat_attachment_ids ON storage.files';
  EXECUTE 'CREATE TRIGGER set_chat_attachment_ids BEFORE INSERT OR UPDATE OF name, bucket_id ON storage.files FOR EACH ROW EXECUTE FUNCTION storage.set_chat_attachment_ids()';

  -- Backfill existing rows for chat-images
  EXECUTE $bf$
    UPDATE storage.files
    SET
      conversation_id = CASE
        WHEN bucket_id='chat-images'
         AND split_part(name,'/',2) ~* '^[0-9a-f-]{36}$'
        THEN split_part(name,'/',2)::uuid
        ELSE conversation_id
      END,
      message_id = CASE
        WHEN bucket_id='chat-images'
         AND split_part(name,'/',3) ~* '^[0-9a-f-]{36}$'
        THEN split_part(name,'/',3)::uuid
        ELSE message_id
      END
    WHERE bucket_id='chat-images'
      AND (conversation_id IS NULL OR message_id IS NULL);
  $bf$;

  -- RLS policies for chat-images bucket on storage.files
  EXECUTE 'ALTER TABLE storage.files ENABLE ROW LEVEL SECURITY';

  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_images_files_select ON storage.files;
    CREATE POLICY chat_images_files_select
    ON storage.files
    FOR SELECT
    TO PUBLIC
    USING (
      bucket_id = 'chat-images'
      AND EXISTS (
        SELECT 1
        FROM public.chat_attachments a
        JOIN public.chat_messages m ON m.id = a.message_id
        JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
        WHERE p.user_uid::text = public.request_uid_text()::text
          AND a.bucket = 'chat-images'
          AND (
            a.path = storage.files.id::text
            OR a.path = storage.files.name
          )
      )
    );

    DROP POLICY IF EXISTS chat_images_files_insert ON storage.files;
    CREATE POLICY chat_images_files_insert
    ON storage.files
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'chat-images'
      AND (
        uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
        OR (
          uploaded_by_user_id IS NULL
          AND nullif(public.request_uid_text(), '') IS NOT NULL
        )
      )
    );

    DROP POLICY IF EXISTS chat_images_files_delete ON storage.files;
    CREATE POLICY chat_images_files_delete
    ON storage.files
    FOR DELETE
    TO PUBLIC
    USING (
      bucket_id = 'chat-images'
      AND EXISTS (
        SELECT 1
        FROM public.chat_attachments a
        JOIN public.chat_messages m ON m.id = a.message_id
        JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
        WHERE p.user_uid::text = public.request_uid_text()::text
          AND a.bucket = 'chat-images'
          AND (
            a.path = storage.files.id::text
            OR a.path = storage.files.name
          )
      )
    );
  $sql$;
END
$do$;

COMMIT;
