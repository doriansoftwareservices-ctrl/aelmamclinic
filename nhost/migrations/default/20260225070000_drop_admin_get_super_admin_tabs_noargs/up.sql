BEGIN;

-- Drop no-argument overload to avoid Hasura inconsistency.
DROP FUNCTION IF EXISTS public.admin_get_super_admin_tabs();

COMMIT;
