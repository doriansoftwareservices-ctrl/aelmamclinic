BEGIN;

-- Ensure email-password provider exists (noop if already present)
INSERT INTO auth.providers (id)
SELECT 'email-password'
WHERE NOT EXISTS (
  SELECT 1 FROM auth.providers WHERE id = 'email-password'
);

-- Create trigger function to ensure auth.user_providers row on signup
CREATE OR REPLACE FUNCTION auth.ensure_user_provider_email_password()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = auth, public
AS $$
BEGIN
  -- Only for email/password users with an email
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
$$;

DROP TRIGGER IF EXISTS trg_ensure_user_provider_email_password ON auth.users;
CREATE TRIGGER trg_ensure_user_provider_email_password
AFTER INSERT OR UPDATE OF email ON auth.users
FOR EACH ROW
EXECUTE FUNCTION auth.ensure_user_provider_email_password();

COMMIT;
