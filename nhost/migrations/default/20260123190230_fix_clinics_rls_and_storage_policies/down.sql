BEGIN;

DO $do$
DECLARE
  is_table boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'clinics'
      AND c.relkind IN ('r', 'p')
  ) INTO is_table;

  IF is_table THEN
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
