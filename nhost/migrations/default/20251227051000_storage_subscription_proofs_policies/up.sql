-- RLS policies for subscription payment proofs in storage

BEGIN;

ALTER TABLE storage.files ENABLE ROW LEVEL SECURITY;

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

DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
CREATE POLICY subscription_proofs_insert
ON storage.files
FOR INSERT
TO PUBLIC
WITH CHECK (
  bucket_id = 'subscription-proofs'
  AND uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files;
CREATE POLICY subscription_proofs_delete
ON storage.files
FOR DELETE
TO PUBLIC
USING (
  bucket_id = 'subscription-proofs'
  AND (
    uploaded_by_user_id = nullif(public.request_uid_text(), '')::uuid
    OR public.fn_is_super_admin() = true
  )
);

COMMIT;
