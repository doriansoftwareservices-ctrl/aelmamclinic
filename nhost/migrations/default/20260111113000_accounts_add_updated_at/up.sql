BEGIN;

-- Add updated_at if missing
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- Backfill existing rows (just in case)
UPDATE public.accounts
SET updated_at = COALESCE(updated_at, now());

-- Keep updated_at fresh on updates (scoped only to accounts)
CREATE OR REPLACE FUNCTION public.tg_accounts_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_accounts_set_updated_at ON public.accounts;

CREATE TRIGGER trg_accounts_set_updated_at
BEFORE UPDATE ON public.accounts
FOR EACH ROW
EXECUTE FUNCTION public.tg_accounts_set_updated_at();

COMMIT;
