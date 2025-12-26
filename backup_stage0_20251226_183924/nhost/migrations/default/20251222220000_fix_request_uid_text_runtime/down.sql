-- Restore previous request_uid_text (JSON-only) behavior.

CREATE OR REPLACE FUNCTION public.request_uid_text()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(
    COALESCE(
      current_setting('hasura.user', true)::json ->> 'x-hasura-user-id',
      current_setting('request.jwt.claims', true)::json ->> 'sub'
    ),
    ''
  );
$$;
