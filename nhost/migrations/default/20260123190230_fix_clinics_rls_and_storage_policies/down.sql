BEGIN;

DO $do$
BEGIN
  IF to_regclass('public.clinics') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS clinics_delete_superadmin ON public.clinics';
    EXECUTE 'DROP POLICY IF EXISTS clinics_update_superadmin ON public.clinics';
    EXECUTE 'DROP POLICY IF EXISTS clinics_insert_superadmin ON public.clinics';
    EXECUTE 'DROP POLICY IF EXISTS clinics_select_member ON public.clinics';
    EXECUTE 'ALTER TABLE public.clinics DISABLE ROW LEVEL SECURITY';
  END IF;
END
$do$;

-- Best-effort drop storage policies (ignore failures if role not available).
DO $do$
BEGIN
  IF to_regclass('storage.files') IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE 'SET LOCAL ROLE nhost_storage_admin';
  EXCEPTION WHEN others THEN
    RETURN;
  END;
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS chat_attachments_files_delete ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_select ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_insert ON storage.files';
  EXECUTE 'DROP POLICY IF EXISTS subscription_proofs_delete ON storage.files';
END
$do$;

COMMIT;
