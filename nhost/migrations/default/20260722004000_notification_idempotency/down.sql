BEGIN;

DROP FUNCTION IF EXISTS public.claim_notification_event(text, text, text);
-- Delivery evidence is intentionally retained for audit and replay safety.

COMMIT;
