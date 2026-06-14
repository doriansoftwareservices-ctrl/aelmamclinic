BEGIN;

-- Conservative rollback: keep the Auth-compatible default role and preserve
-- production superadmin mappings.
UPDATE auth.users
SET updated_at = now()
WHERE lower(email) = lower('elmamclinic.admin@elmam.com');

COMMIT;
