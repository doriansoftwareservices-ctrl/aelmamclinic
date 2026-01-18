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
END $$;
