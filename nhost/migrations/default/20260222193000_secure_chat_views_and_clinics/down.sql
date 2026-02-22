BEGIN;

-- Revert clinics view to unfiltered accounts projection.
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

-- Revert chat last message view (no membership filter).
DO $do$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    EXECUTE $$
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
      ) lm ON true;
    $$;
  END IF;
END
$do$;

-- Revert typing activity view (no membership filter).
DO $do$
BEGIN
  IF to_regclass('public.chat_typing') IS NOT NULL THEN
    EXECUTE $$
      CREATE OR REPLACE VIEW public.v_chat_typing_active AS
      SELECT
        t.conversation_id,
        t.user_uid,
        t.email,
        t.updated_at
      FROM public.chat_typing t
      WHERE t.typing = true
        AND t.updated_at > (now() - interval '15 seconds');
    $$;
  END IF;
END
$do$;

COMMIT;
