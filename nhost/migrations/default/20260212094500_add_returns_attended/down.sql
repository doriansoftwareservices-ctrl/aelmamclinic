BEGIN;

ALTER TABLE public.returns
  DROP COLUMN IF EXISTS attended_at;

ALTER TABLE public.returns
  DROP COLUMN IF EXISTS is_attended;

COMMIT;
