-- Irreversible by design: minor-unit values and reconciliation evidence may
-- be newer than their legacy representations. Removing columns, triggers, or
-- tenant constraints would silently reopen data-integrity defects.
DO $do$
BEGIN
  RAISE EXCEPTION
    '20260722005000 is irreversible; deploy a reviewed forward-fix migration';
END
$do$;
