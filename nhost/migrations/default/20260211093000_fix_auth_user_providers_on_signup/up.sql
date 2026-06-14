BEGIN;

-- Nhost Cloud owns the internal auth schema.  On recreated projects the
-- migration role may be allowed to run application/public migrations but not
-- to create functions or triggers inside auth.*.  Treat this compatibility
-- migration as optional: run it only when the current role can safely manage
-- auth.users; otherwise skip it instead of failing the whole deployment.
DO $$
DECLARE
  can_manage_auth_users boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE n.nspname = 'auth'
      AND c.relname = 'users'
      AND r.rolname = current_user
  )
  AND has_schema_privilege('auth', 'USAGE')
  AND has_schema_privilege('auth', 'CREATE')
  INTO can_manage_auth_users;

  IF NOT can_manage_auth_users THEN
    RAISE NOTICE 'Skipping auth.ensure_user_provider_email_password migration: current role % is not owner/creator for auth.users/auth schema', current_user;
    RETURN;
  END IF;

  IF to_regclass('auth.providers') IS NOT NULL THEN
    EXECUTE $sql$
      INSERT INTO auth.providers (id)
      SELECT 'email-password'
      WHERE NOT EXISTS (
        SELECT 1 FROM auth.providers WHERE id = 'email-password'
      )
    $sql$;
  END IF;

  EXECUTE $sql$
    CREATE OR REPLACE FUNCTION auth.ensure_user_provider_email_password()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = auth, public
    AS $fn$
    BEGIN
      IF NEW.email IS NULL OR NEW.email = '' THEN
        RETURN NEW;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM auth.user_providers up
        WHERE up.user_id = NEW.id
          AND up.provider_id = 'email-password'
      ) THEN
        INSERT INTO auth.user_providers (
          id,
          user_id,
          provider_id,
          provider_user_id,
          created_at,
          updated_at
        ) VALUES (
          gen_random_uuid(),
          NEW.id,
          'email-password',
          NEW.email,
          now(),
          now()
        );
      END IF;

      RETURN NEW;
    END;
    $fn$;
  $sql$;

  EXECUTE 'DROP TRIGGER IF EXISTS trg_ensure_user_provider_email_password ON auth.users';
  EXECUTE $sql$
    CREATE TRIGGER trg_ensure_user_provider_email_password
    AFTER INSERT OR UPDATE OF email ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION auth.ensure_user_provider_email_password()
  $sql$;
END;
$$;

COMMIT;
