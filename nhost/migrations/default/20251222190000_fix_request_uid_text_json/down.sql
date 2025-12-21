-- Restore prior simple request_uid_text implementation.

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
