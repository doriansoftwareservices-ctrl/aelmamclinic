BEGIN;

DROP FUNCTION IF EXISTS public.self_create_account(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
);

COMMIT;
