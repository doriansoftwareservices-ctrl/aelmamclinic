BEGIN;

DROP TRIGGER IF EXISTS trg_accounts_set_updated_at ON public.accounts;
DROP FUNCTION IF EXISTS public.tg_accounts_set_updated_at();

ALTER TABLE public.accounts
  DROP COLUMN IF EXISTS updated_at;

COMMIT;
