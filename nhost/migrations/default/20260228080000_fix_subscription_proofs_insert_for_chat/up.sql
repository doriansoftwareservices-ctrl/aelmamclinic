BEGIN;

-- Allow chat participants (and owners/admins) to INSERT subscription-proofs files.
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
    DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
    CREATE POLICY subscription_proofs_insert
    ON storage.files
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      bucket_id = 'subscription-proofs'
      AND (
        public.fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.account_users au
          WHERE au.user_uid::text = public.request_uid_text()::text
            AND coalesce(au.disabled, false) = false
            AND lower(au.role) IN ('owner','admin')
        )
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.user_uid::text = public.request_uid_text()::text
            AND p.conversation_id = CASE
              WHEN (storage.files.metadata->>'conversation_id') ~* '^[0-9a-f-]{36}$'
              THEN (storage.files.metadata->>'conversation_id')::uuid
              ELSE NULL
            END
        )
      )
    );
  $sql$;
END
$do$;

COMMIT;
