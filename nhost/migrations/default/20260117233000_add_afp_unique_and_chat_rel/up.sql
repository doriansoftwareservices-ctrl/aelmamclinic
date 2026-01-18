DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'account_feature_permissions_uix'
      AND conrelid = 'public.account_feature_permissions'::regclass
  ) THEN
    ALTER TABLE public.account_feature_permissions
      ADD CONSTRAINT account_feature_permissions_uix
      UNIQUE (account_id, user_uid);
  END IF;
END $$;
