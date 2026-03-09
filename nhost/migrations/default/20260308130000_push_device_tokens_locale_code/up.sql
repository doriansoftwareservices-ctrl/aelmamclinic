DO $$
BEGIN
  IF to_regclass('public.push_device_tokens') IS NULL THEN
    RETURN;
  END IF;

  ALTER TABLE public.push_device_tokens
    ADD COLUMN IF NOT EXISTS locale_code text;

  UPDATE public.push_device_tokens
     SET locale_code = 'ar'
   WHERE locale_code IS NULL
      OR btrim(locale_code) = ''
      OR lower(locale_code) NOT IN ('ar', 'en');

  ALTER TABLE public.push_device_tokens
    ALTER COLUMN locale_code SET DEFAULT 'ar';

  ALTER TABLE public.push_device_tokens
    ALTER COLUMN locale_code SET NOT NULL;

  ALTER TABLE public.push_device_tokens
    DROP CONSTRAINT IF EXISTS push_device_tokens_locale_code_check;

  ALTER TABLE public.push_device_tokens
    ADD CONSTRAINT push_device_tokens_locale_code_check
    CHECK (locale_code IN ('ar', 'en'));
END $$;
