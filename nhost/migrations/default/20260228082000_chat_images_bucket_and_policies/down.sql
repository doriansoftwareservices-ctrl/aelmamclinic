BEGIN;

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

  EXECUTE $sql$
    DROP POLICY IF EXISTS chat_images_files_select ON storage.files;
    DROP POLICY IF EXISTS chat_images_files_insert ON storage.files;
    DROP POLICY IF EXISTS chat_images_files_delete ON storage.files;
  $sql$;
END
$do$;

DELETE FROM storage.buckets WHERE id = 'chat-images';

COMMIT;
