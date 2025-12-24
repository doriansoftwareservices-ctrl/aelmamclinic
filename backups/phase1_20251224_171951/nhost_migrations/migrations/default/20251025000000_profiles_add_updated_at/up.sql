-- add updated_at if missing and make it NOT NULL with default now()
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;
UPDATE public.profiles
SET updated_at = COALESCE(updated_at, created_at, now());
ALTER TABLE public.profiles
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL;
-- ensure function exists
CREATE OR REPLACE FUNCTION public.tg_profiles_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
-- ensure trigger exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid=t.tgrelid
    WHERE c.relname='profiles' AND t.tgname='profiles_set_updated_at'
  ) THEN
    CREATE TRIGGER profiles_set_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.tg_profiles_set_updated_at();
  END IF;
END $$;
