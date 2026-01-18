DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'account_feature_permissions_uix'
      AND conrelid = 'public.account_feature_permissions'::regclass
  ) THEN
    ALTER TABLE public.account_feature_permissions
      DROP CONSTRAINT account_feature_permissions_uix;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'account_feature_permissions_uix'
      AND n.nspname = 'public'
      AND i.indrelid = 'public.account_feature_permissions'::regclass
  ) THEN
    EXECUTE 'DROP INDEX IF EXISTS public.account_feature_permissions_uix';
  END IF;
END $$;
