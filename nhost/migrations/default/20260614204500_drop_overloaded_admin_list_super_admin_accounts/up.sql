BEGIN;

-- Nhost/Hasura does not track overloaded SQL functions in metadata.
-- Keep the current session-aware JSON variant and remove the legacy no-arg overload.
DROP FUNCTION IF EXISTS public.admin_list_super_admin_accounts();

COMMIT;
