BEGIN;

-- Re-introduce afp_write_service in a SAFE way (service-only), for rollback scenarios.
-- NOTE: this does NOT restore the original insecure policy.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='account_feature_permissions'
      AND policyname='afp_write_service'
  ) THEN
    CREATE POLICY afp_write_service
    ON public.account_feature_permissions
    FOR ALL
    TO PUBLIC
    USING (
      COALESCE(NULLIF(current_setting('hasura.user', true), ''), '{}')::json->>'x-hasura-role' = 'service'
    )
    WITH CHECK (
      COALESCE(NULLIF(current_setting('hasura.user', true), ''), '{}')::json->>'x-hasura-role' = 'service'
    );
  END IF;
END$$;

COMMIT;
