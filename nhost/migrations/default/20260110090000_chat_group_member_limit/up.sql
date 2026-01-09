BEGIN;

CREATE OR REPLACE FUNCTION public.chat_group_member_limit_check()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_group boolean;
  v_count integer;
BEGIN
  SELECT is_group
    INTO v_is_group
    FROM public.chat_conversations
   WHERE id = NEW.conversation_id;

  IF COALESCE(v_is_group, false) = false THEN
    RETURN NEW;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM public.chat_participants
   WHERE conversation_id = NEW.conversation_id;

  IF v_count >= 100 THEN
    RAISE EXCEPTION 'group member limit reached' USING errcode = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_group_member_limit ON public.chat_participants;
CREATE TRIGGER chat_group_member_limit
BEFORE INSERT ON public.chat_participants
FOR EACH ROW
EXECUTE FUNCTION public.chat_group_member_limit_check();

COMMIT;
