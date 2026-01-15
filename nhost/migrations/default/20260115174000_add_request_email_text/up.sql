-- Provide a robust request_email_text helper (similar to request_uid_text).

BEGIN;

CREATE OR REPLACE FUNCTION public.request_email_text()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  email_text text;
  email_regex text;
BEGIN
  IF raw_hasura_user IS NOT NULL AND raw_hasura_user <> '' THEN
    BEGIN
      hasura_user := raw_hasura_user::jsonb;
    EXCEPTION WHEN others THEN
      hasura_user := '{}'::jsonb;
    END;
  END IF;

  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  email_text := NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.email', true),
      current_setting('request.jwt.claim.x-hasura-user-email', true)
    ),
    ''
  );

  IF email_text IS NULL THEN
    email_text := COALESCE(
      hasura_user ->> 'x-hasura-user-email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'email',
      claims ->> 'x-hasura-user-email',
      claims ->> 'email'
    );
  END IF;

  IF email_text IS NULL AND raw_hasura_user IS NOT NULL THEN
    email_regex := regexp_replace(
      raw_hasura_user,
      '.*\"x-hasura-user-email\"\\s*:\\s*\"([^\"]+)\".*',
      '\\1'
    );
    IF email_regex IS NOT NULL AND email_regex <> raw_hasura_user THEN
      email_text := email_regex;
    END IF;
  END IF;

  IF email_text IS NULL AND raw_claims IS NOT NULL THEN
    email_regex := regexp_replace(
      raw_claims,
      '.*\"email\"\\s*:\\s*\"([^\"]+)\".*',
      '\\1'
    );
    IF email_regex IS NOT NULL AND email_regex <> raw_claims THEN
      email_text := email_regex;
    END IF;
  END IF;

  RETURN NULLIF(email_text, '');
END;
$$;

REVOKE ALL ON FUNCTION public.request_email_text() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_email_text() TO PUBLIC;

COMMIT;
