BEGIN;

-- Forward-only safety rollback: preserve ownership and quarantine evidence.
-- Dropping these records could make existing medical attachments ambiguous.
DO $do$
BEGIN
  RAISE NOTICE 'chat attachment ownership evidence preserved intentionally';
END
$do$;

COMMIT;