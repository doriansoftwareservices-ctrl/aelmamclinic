BEGIN;

-- Nhost Auth can fail while generating a JWT when a custom application role is
-- stored as auth.users.default_role. Keep login stable by using the built-in
-- user role as the default, while preserving superadmin in auth.user_roles and
-- public.super_admins. The Flutter client detects superadmin from allowed roles
-- and sends x-hasura-role: superadmin for privileged GraphQL calls.
UPDATE auth.users u
SET default_role = 'user',
    email_verified = true,
    disabled = false,
    metadata = coalesce(u.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'role', 'superadmin',
        'root', true,
        'auth_default_role', 'user',
        'source', 'migration:20260615005500'
      ),
    updated_at = now()
WHERE lower(u.email) = lower('elmamclinic.admin@elmam.com')
  AND EXISTS (
    SELECT 1
    FROM auth.user_roles ur
    WHERE ur.user_id = u.id
      AND ur.role = 'superadmin'
  );

INSERT INTO auth.roles(role)
SELECT role
FROM unnest(ARRAY['user','me','superadmin']::text[]) AS role
ON CONFLICT DO NOTHING;

INSERT INTO auth.user_roles(user_id, role)
SELECT u.id, role
FROM auth.users u
CROSS JOIN unnest(ARRAY['user','me','superadmin']::text[]) AS role
WHERE lower(u.email) = lower('elmamclinic.admin@elmam.com')
ON CONFLICT DO NOTHING;

COMMIT;
