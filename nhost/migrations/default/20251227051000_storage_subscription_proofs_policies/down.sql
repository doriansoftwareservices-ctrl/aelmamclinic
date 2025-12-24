BEGIN;

DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files;
DROP POLICY IF EXISTS subscription_proofs_select ON storage.files;

COMMIT;
