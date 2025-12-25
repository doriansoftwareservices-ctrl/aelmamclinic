-- Recreate chat helper views if missing.

DO $m$
BEGIN
  IF to_regclass('public.chat_messages') IS NULL THEN
    RAISE NOTICE 'skip chat views: chat_messages not present';
    RETURN;
  END IF;

  EXECUTE $sql$
    SET search_path TO public;

    DROP VIEW IF EXISTS public.v_chat_conversations_for_me;
    DROP VIEW IF EXISTS public.v_chat_reads_for_me;
    DROP VIEW IF EXISTS public.v_chat_last_message;
    DROP VIEW IF EXISTS public.v_chat_messages_with_attachments;

    CREATE OR REPLACE VIEW public.v_chat_messages_with_attachments AS
    SELECT
      m.id,
      m.conversation_id,
      m.sender_uid,
      m.sender_email,
      m.kind,
      m.body,
      m.created_at,
      m.edited,
      m.deleted,
      m.edited_at,
      m.deleted_at,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id',       a.id,
            'message_id', a.message_id,
            'bucket',   a.bucket,
            'path',     a.path,
            'mime_type',a.mime_type,
            'size_bytes', a.size_bytes,
            'width',    a.width,
            'height',   a.height,
            'created_at', a.created_at
          )
        ) FILTER (WHERE a.id IS NOT NULL),
        '[]'::jsonb
      ) AS attachments
    FROM public.chat_messages m
    LEFT JOIN public.chat_attachments a
      ON a.message_id = m.id
    GROUP BY
      m.id, m.conversation_id, m.sender_uid, m.sender_email, m.kind, m.body,
      m.created_at, m.edited, m.deleted, m.edited_at, m.deleted_at;

    CREATE OR REPLACE VIEW public.v_chat_last_message AS
    SELECT
      c.id AS conversation_id,
      lm.id AS last_message_id,
      lm.kind AS last_message_kind,
      lm.body AS last_message_body,
      lm.created_at AS last_message_created_at
    FROM public.chat_conversations c
    LEFT JOIN LATERAL (
      SELECT m.id, m.kind, m.body, m.created_at
      FROM public.chat_messages m
      WHERE m.conversation_id = c.id
        AND COALESCE(m.deleted, false) = false
      ORDER BY m.created_at DESC
      LIMIT 1
    ) lm ON TRUE;

    CREATE OR REPLACE VIEW public.v_chat_reads_for_me AS
    SELECT
      r.conversation_id,
      r.last_read_message_id,
      r.last_read_at
    FROM public.chat_reads r
    WHERE r.user_uid = nullif(public.request_uid_text(), '')::uuid;

    CREATE OR REPLACE VIEW public.v_chat_conversations_for_me AS
    WITH mine AS (
      SELECT p.conversation_id
      FROM public.chat_participants p
      WHERE p.user_uid = nullif(public.request_uid_text(), '')::uuid
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
    JOIN mine m
      ON m.conversation_id = c.id
    LEFT JOIN public.v_chat_last_message lm
      ON lm.conversation_id = c.id
    LEFT JOIN unread u
      ON u.conversation_id = c.id;

    REVOKE ALL ON TABLE public.v_chat_messages_with_attachments FROM PUBLIC;
    REVOKE ALL ON TABLE public.v_chat_last_message FROM PUBLIC;
    REVOKE ALL ON TABLE public.v_chat_reads_for_me FROM PUBLIC;
    REVOKE ALL ON TABLE public.v_chat_conversations_for_me FROM PUBLIC;
    GRANT SELECT ON TABLE public.v_chat_messages_with_attachments TO PUBLIC;
    GRANT SELECT ON TABLE public.v_chat_last_message TO PUBLIC;
    GRANT SELECT ON TABLE public.v_chat_reads_for_me TO PUBLIC;
    GRANT SELECT ON TABLE public.v_chat_conversations_for_me TO PUBLIC;
  $sql$;
END;
$m$;
