BEGIN;

DROP TRIGGER IF EXISTS chat_group_member_limit ON public.chat_participants;
DROP FUNCTION IF EXISTS public.chat_group_member_limit_check();

COMMIT;
