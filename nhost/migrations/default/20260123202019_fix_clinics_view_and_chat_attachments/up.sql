BEGIN;

-- Ensure clinics view exposes id/name/frozen/created_at
DO $do$
BEGIN
  IF to_regclass('public.accounts') IS NOT NULL THEN
    EXECUTE $$
      CREATE OR REPLACE VIEW public.clinics AS
      SELECT id, name, frozen, created_at
      FROM public.accounts;
    $$;
  END IF;
END
$do$;

-- Ensure chat_attachments.message_id exists with FK + index
DO $do$
BEGIN
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_attachments'
        AND column_name = 'message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_attachments ADD COLUMN message_id uuid';
    END IF;

    EXECUTE 'ALTER TABLE public.chat_attachments DROP CONSTRAINT IF EXISTS chat_attachments_message_id_fkey';
    EXECUTE 'ALTER TABLE public.chat_attachments ADD CONSTRAINT chat_attachments_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE';
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_chat_attachments_message_id ON public.chat_attachments (message_id)';
  END IF;
END
$do$;

COMMIT;
