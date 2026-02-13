BEGIN;

ALTER TABLE public.returns
  ADD COLUMN IF NOT EXISTS is_attended boolean NOT NULL DEFAULT false;

ALTER TABLE public.returns
  ADD COLUMN IF NOT EXISTS attended_at timestamptz;

COMMIT;
