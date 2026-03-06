DO $$
BEGIN
  IF to_regclass('public.push_device_tokens') IS NOT NULL THEN
    DROP TABLE public.push_device_tokens;
  END IF;
END $$;
