-- Add support_status to chat_conversations and expose in v_chat_conversations_for_me

DO $m$
BEGIN
  IF to_regclass('public.chat_conversations') IS NULL THEN
    RAISE NOTICE 'skip support_status patch: chat_conversations not present';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_conversations'
      AND column_name = 'support_status'
  ) THEN
    EXECUTE 'ALTER TABLE public.chat_conversations ADD COLUMN support_status text';
  END IF;

  BEGIN
    EXECUTE 'ALTER TABLE public.chat_conversations ALTER COLUMN support_status SET DEFAULT ''pending''';
  EXCEPTION WHEN others THEN
    NULL;
  END;

  EXECUTE 'UPDATE public.chat_conversations SET support_status = ''pending'' WHERE support_status IS NULL';

  BEGIN
    EXECUTE 'ALTER TABLE public.chat_conversations ALTER COLUMN support_status SET NOT NULL';
  EXCEPTION WHEN others THEN
    NULL;
  END;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chat_conversations_support_status_chk'
  ) THEN
    EXECUTE 'ALTER TABLE public.chat_conversations ADD CONSTRAINT chat_conversations_support_status_chk CHECK (support_status IN (''pending'',''under_review'',''responded'',''closed''))';
  END IF;
END;
$m$;

DO $m$
DECLARE
  has_admins_only boolean := false;
  has_is_frozen boolean := false;
BEGIN
  IF to_regclass('public.chat_conversations') IS NULL
     OR to_regclass('public.chat_messages') IS NULL
     OR to_regclass('public.chat_participants') IS NULL THEN
    RAISE NOTICE 'skip chat view patch: chat tables not present';
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_conversations'
      AND column_name = 'admins_only'
  ) INTO has_admins_only;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_conversations'
      AND column_name = 'is_frozen'
  ) INTO has_is_frozen;

  IF has_admins_only AND has_is_frozen THEN
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
              AND (m.sender_uid IS NULL
                   OR m.sender_uid <> nullif(public.request_uid_text(), '')::uuid)
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
        c.is_frozen,
        c.admins_only,
        c.support_status,
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
      WHERE m.conversation_id IS NOT NULL
         OR c.created_by = nullif(public.request_uid_text(), '')::uuid;
    $sql$;
  ELSIF has_admins_only AND NOT has_is_frozen THEN
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
              AND (m.sender_uid IS NULL
                   OR m.sender_uid <> nullif(public.request_uid_text(), '')::uuid)
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
        false::boolean AS is_frozen,
        c.admins_only,
        c.support_status,
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
      WHERE m.conversation_id IS NOT NULL
         OR c.created_by = nullif(public.request_uid_text(), '')::uuid;
    $sql$;
  ELSIF NOT has_admins_only AND has_is_frozen THEN
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
              AND (m.sender_uid IS NULL
                   OR m.sender_uid <> nullif(public.request_uid_text(), '')::uuid)
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
        c.is_frozen,
        false::boolean AS admins_only,
        c.support_status,
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
      WHERE m.conversation_id IS NOT NULL
         OR c.created_by = nullif(public.request_uid_text(), '')::uuid;
    $sql$;
  ELSE
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
              AND (m.sender_uid IS NULL
                   OR m.sender_uid <> nullif(public.request_uid_text(), '')::uuid)
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
        false::boolean AS is_frozen,
        false::boolean AS admins_only,
        c.support_status,
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
      WHERE m.conversation_id IS NOT NULL
         OR c.created_by = nullif(public.request_uid_text(), '')::uuid;
    $sql$;
  END IF;
END;
$m$;
