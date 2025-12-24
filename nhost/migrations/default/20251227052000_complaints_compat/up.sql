-- Ensure complaints schema compatibility (title/description vs subject/message)
DO $do$
BEGIN
  IF to_regclass('public.complaints') IS NULL THEN
    RAISE NOTICE 'skip complaints compat: table missing';
    RETURN;
  END IF;

  ALTER TABLE public.complaints
    ADD COLUMN IF NOT EXISTS title text,
    ADD COLUMN IF NOT EXISTS description text,
    ADD COLUMN IF NOT EXISTS subject text,
    ADD COLUMN IF NOT EXISTS message text;

  UPDATE public.complaints
  SET subject = COALESCE(subject, title),
      message = COALESCE(message, description),
      title = COALESCE(title, subject),
      description = COALESCE(description, message);

  CREATE OR REPLACE FUNCTION public.tg_sync_complaints_fields()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $fn$
  BEGIN
    NEW.subject := COALESCE(NEW.subject, NEW.title);
    NEW.message := COALESCE(NEW.message, NEW.description);
    NEW.title := COALESCE(NEW.title, NEW.subject);
    NEW.description := COALESCE(NEW.description, NEW.message);
    RETURN NEW;
  END;
  $fn$;

  DROP TRIGGER IF EXISTS complaints_sync_fields ON public.complaints;
  CREATE TRIGGER complaints_sync_fields
    BEFORE INSERT OR UPDATE ON public.complaints
    FOR EACH ROW
    EXECUTE FUNCTION public.tg_sync_complaints_fields();
END
$do$;
