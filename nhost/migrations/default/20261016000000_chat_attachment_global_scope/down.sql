BEGIN;
-- Forward-only safety rollback, matching the ownership foundation migration.
-- Keep global scopes and the stricter authority/claim checks. Reverting the
-- nullable column could discard or invalidate existing attachment evidence.
DO $do$
BEGIN
  RAISE NOTICE 'chat attachment global ownership and authority preserved intentionally';
END
$do$;
COMMIT;
