DO $$
BEGIN
  IF to_regclass('public.push_device_tokens') IS NULL THEN
    RETURN;
  END IF;

  ALTER TABLE public.push_device_tokens
    DROP CONSTRAINT IF EXISTS push_device_tokens_locale_code_check;

  ALTER TABLE public.push_device_tokens
    DROP COLUMN IF EXISTS locale_code;
END $$;
