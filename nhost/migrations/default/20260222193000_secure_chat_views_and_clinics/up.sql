BEGIN;

-- Secure clinics view: limit to superadmin or current account membership.
DO $do$
BEGIN
  IF to_regclass('public.accounts') IS NOT NULL THEN
    EXECUTE $$
      CREATE OR REPLACE VIEW public.clinics AS
      SELECT a.id, a.name, a.frozen, a.created_at
      FROM public.accounts a
      WHERE public.fn_is_super_admin() = true
         OR EXISTS (
           SELECT 1
           FROM public.account_users au
           WHERE au.account_id = a.id
             AND au.user_uid = nullif(public.request_uid_text(), '')::uuid
             AND au.disabled = false
         );
    $$;
  END IF;
END
$do$;

-- Secure chat last message view: only for conversation members or superadmin.
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
      ) lm ON true
      WHERE public.fn_is_super_admin() = true
         OR c.created_by = nullif(public.request_uid_text(), '')::uuid
         OR EXISTS (
           SELECT 1
           FROM public.chat_participants p
           WHERE p.conversation_id = c.id
             AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
             AND COALESCE(p.is_deleted, false) = false
         );
    $$;
  END IF;
END
$do$;

-- Secure typing activity view: only for conversation members or superadmin.
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
        AND t.updated_at > (now() - interval '15 seconds')
        AND (
          public.fn_is_super_admin() = true
          OR EXISTS (
            SELECT 1
            FROM public.chat_participants p
            WHERE p.conversation_id = t.conversation_id
              AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
              AND COALESCE(p.is_deleted, false) = false
          )
        );
    $$;
  END IF;
END
$do$;

COMMIT;
