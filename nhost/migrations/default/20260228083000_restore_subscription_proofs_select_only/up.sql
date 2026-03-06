BEGIN;

-- Restore subscription_proofs_select to uploader/super-admin only (remove chat linkage).
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

  EXECUTE 'ALTER TABLE storage.files ENABLE ROW LEVEL SECURITY';

  EXECUTE $sql$
    DROP POLICY IF EXISTS subscription_proofs_select ON storage.files;
    CREATE POLICY subscription_proofs_select
    ON storage.files
    FOR SELECT
    TO PUBLIC
    USING (
      bucket_id = 'subscription-proofs'
      AND (
        uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
        OR public.fn_is_super_admin() = true
      )
    );
  $sql$;
END
$do$;

COMMIT;
