-- Revert unread_count to include sender's own messages.
DO $m$
BEGIN
  IF to_regclass('public.chat_conversations') IS NULL
     OR to_regclass('public.chat_messages') IS NULL
     OR to_regclass('public.chat_participants') IS NULL THEN
    RAISE NOTICE 'skip unread_count revert: chat tables not present';
    RETURN;
  END IF;

  EXECUTE $sql$
    SET search_path TO public;

    DROP VIEW IF EXISTS public.v_chat_conversations_for_me;

    CREATE OR REPLACE VIEW public.v_chat_conversations_for_me AS
    WITH mine AS (
      SELECT p.conversation_id
      FROM public.chat_participants p
      WHERE p.user_uid = nullif(public.request_uid_text(), '')::uuid
        AND COALESCE(p.is_deleted, false) = false
    ),
    unread AS (
      SELECT
        c.id AS conversation_id,
        r.last_read_at,
        (
          SELECT COUNT(1)
          FROM public.chat_messages m
          WHERE m.conversation_id = c.id
            AND COALESCE(m.deleted, false) = false
            AND (
              r.last_read_at IS NULL
              OR m.created_at > r.last_read_at
            )
        )::int AS unread_count
      FROM public.chat_conversations c
      LEFT JOIN public.v_chat_reads_for_me r
        ON r.conversation_id = c.id
    )
    SELECT
      c.id,
      c.account_id,
      c.is_group,
      c.title,
      c.created_by,
      c.created_at,
      c.updated_at,
      c.last_msg_at,
      c.last_msg_snippet,
      lm.last_message_id,
      lm.last_message_kind,
      lm.last_message_body,
      lm.last_message_created_at,
      u.last_read_at,
      u.unread_count,
      CASE
        WHEN lm.last_message_kind = 'image' THEN 'image'
        WHEN lm.last_message_body IS NULL OR btrim(lm.last_message_body) = '' THEN NULL
        WHEN char_length(lm.last_message_body) > 64
          THEN substr(lm.last_message_body, 1, 64) || '...'
        ELSE lm.last_message_body
      END AS last_message_text
    FROM public.chat_conversations c
    LEFT JOIN mine m
      ON m.conversation_id = c.id
    LEFT JOIN public.v_chat_last_message lm
      ON lm.conversation_id = c.id
    LEFT JOIN unread u
      ON u.conversation_id = c.id
    WHERE public.fn_is_super_admin() = true
       OR m.conversation_id IS NOT NULL;
  $sql$;
END;
$m$;
