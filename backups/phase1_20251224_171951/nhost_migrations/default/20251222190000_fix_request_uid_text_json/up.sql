-- Make request_uid_text robust to non-JSON settings.

CREATE OR REPLACE FUNCTION public.request_uid_text()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  uid_text text;
  uid_regex text;
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

  uid_text := NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.sub', true),
      current_setting('request.jwt.claim.x-hasura-user-id', true)
    ),
    ''
  );

  IF uid_text IS NULL THEN
    uid_text := COALESCE(
      hasura_user ->> 'x-hasura-user-id',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
      claims ->> 'x-hasura-user-id',
      claims ->> 'sub'
    );
  END IF;

  IF uid_text IS NULL AND raw_hasura_user IS NOT NULL THEN
    uid_regex := regexp_replace(
      raw_hasura_user,
      '.*"x-hasura-user-id"\\s*:\\s*"([^"]+)".*',
      '\\1'
    );
    IF uid_regex IS NOT NULL AND uid_regex <> raw_hasura_user THEN
      uid_text := uid_regex;
    END IF;
  END IF;

  IF uid_text IS NULL AND raw_claims IS NOT NULL THEN
    uid_regex := regexp_replace(
      raw_claims,
      '.*"x-hasura-user-id"\\s*:\\s*"([^"]+)".*',
      '\\1'
    );
    IF uid_regex IS NOT NULL AND uid_regex <> raw_claims THEN
      uid_text := uid_regex;
    END IF;
  END IF;

  RETURN NULLIF(uid_text, '');
END;
$$;
