BEGIN;

-- CR-SEC-1: Remove the overly-permissive policy that allows ANY user to write feature permissions.
-- Origin: nhost/migrations/default/20251025080000_patch/up.sql (policy afp_write_service).

DROP POLICY IF EXISTS afp_write_service ON public.account_feature_permissions;

COMMIT;
