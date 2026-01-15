BEGIN;

REVOKE ALL ON FUNCTION public.admin_reply_complaint(uuid, text, text) FROM PUBLIC;
DROP FUNCTION IF EXISTS public.admin_reply_complaint(uuid, text, text);

ALTER TABLE public.complaints
  DROP COLUMN IF EXISTS reply_message,
  DROP COLUMN IF EXISTS replied_at,
  DROP COLUMN IF EXISTS replied_by;

COMMIT;
