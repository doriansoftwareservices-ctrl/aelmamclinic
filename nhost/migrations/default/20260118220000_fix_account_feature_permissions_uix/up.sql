DO $$
BEGIN
  IF to_regclass('public.account_feature_permissions') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'account_feature_permissions_uix'
      AND conrelid = 'public.account_feature_permissions'::regclass
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'account_feature_permissions_uix'
        AND c.relkind = 'i'
    ) THEN
      ALTER TABLE public.account_feature_permissions
        ADD CONSTRAINT account_feature_permissions_uix
        UNIQUE USING INDEX account_feature_permissions_uix;
    ELSE
      ALTER TABLE public.account_feature_permissions
        ADD CONSTRAINT account_feature_permissions_uix
        UNIQUE (account_id, user_uid);
    END IF;
  END IF;
END $$;
