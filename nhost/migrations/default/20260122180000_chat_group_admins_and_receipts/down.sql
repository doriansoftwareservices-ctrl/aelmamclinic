BEGIN;

-- Remove trigger and guard function
DROP TRIGGER IF EXISTS chat_messages_guard_send ON public.chat_messages;
DROP FUNCTION IF EXISTS public.tg_chat_messages_guard_send();
DROP FUNCTION IF EXISTS public.chat_can_send(uuid, uuid);

-- Drop group admin RPCs
DROP FUNCTION IF EXISTS public.chat_group_delete(uuid);
DROP FUNCTION IF EXISTS public.chat_group_remove_member(uuid, uuid);
DROP FUNCTION IF EXISTS public.chat_group_set_member_role(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.chat_group_set_frozen(uuid, boolean, boolean);
DROP FUNCTION IF EXISTS public.chat_group_set_title(uuid, text);

-- Revert view to previous signature (keep if exists)
DROP VIEW IF EXISTS public.v_chat_reads_for_me;
-- Do not drop v_chat_conversations_for_me here; leave to later migrations.

-- Remove added columns (if exist)
DO $$
BEGIN
  IF to_regclass('public.chat_reads') IS NOT NULL THEN
    ALTER TABLE public.chat_reads
      DROP COLUMN IF EXISTS last_delivered_message_id,
      DROP COLUMN IF EXISTS last_delivered_at;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    ALTER TABLE public.chat_participants
      DROP COLUMN IF EXISTS is_deleted,
      DROP COLUMN IF EXISTS deleted_at,
      DROP COLUMN IF EXISTS role;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    ALTER TABLE public.chat_conversations
      DROP COLUMN IF EXISTS is_frozen,
      DROP COLUMN IF EXISTS admins_only;
  END IF;
END $$;

COMMIT;
