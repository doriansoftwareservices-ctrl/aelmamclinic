BEGIN;

-- Keep composite uniqueness on mutation ids during rollback. Restoring global
-- uniqueness or cross-tenant foreign keys would reintroduce the vulnerability.
DROP INDEX IF EXISTS public.sync_events_account_client_mutation_uix;
ALTER TABLE public.sync_events
  DROP COLUMN IF EXISTS correlation_id,
  DROP COLUMN IF EXISTS client_mutation_id;
ALTER TABLE public.client_mutations
  DROP COLUMN IF EXISTS completed_at,
  DROP COLUMN IF EXISTS correlation_id;

COMMIT;
