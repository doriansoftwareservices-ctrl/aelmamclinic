BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Ensure request_uid_text() exists (needed by views/RPCs below)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regproc('public.request_uid_text()') IS NULL THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION public.request_uid_text()
      RETURNS text
      LANGUAGE plpgsql
      STABLE
      AS $body$
      DECLARE
        raw_hasura_user text := current_setting('hasura.user', true);
        raw_claims text := current_setting('request.jwt.claims', true);
        hasura_user jsonb := '{}'::jsonb;
        claims jsonb := '{}'::jsonb;
        uid_text text;
        uid_regex text;
      BEGIN
        IF raw_hasura_user IS NOT NULL AND raw_hasura_user <> '' THEN
          BEGIN
            hasura_user := raw_hasura_user::jsonb;
          EXCEPTION WHEN others THEN
            hasura_user := '{}'::jsonb;
          END;
        END IF;

        IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
          BEGIN
            claims := raw_claims::jsonb;
          EXCEPTION WHEN others THEN
            claims := '{}'::jsonb;
          END;
        END IF;

        uid_text := NULLIF(
          COALESCE(
            current_setting('request.jwt.claim.sub', true),
            current_setting('request.jwt.claim.x-hasura-user-id', true)
          ),
          ''
        );

        IF uid_text IS NULL THEN
          uid_text := COALESCE(
            hasura_user ->> 'x-hasura-user-id',
            claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
            claims ->> 'x-hasura-user-id',
            claims ->> 'sub'
          );
        END IF;

        IF uid_text IS NULL AND raw_hasura_user IS NOT NULL THEN
          uid_regex := regexp_replace(
            raw_hasura_user,
            '.*"x-hasura-user-id"\\s*:\\s*"([^"]+)".*',
            '\\1'
          );
          IF uid_regex IS NOT NULL AND uid_regex <> raw_hasura_user THEN
            uid_text := uid_regex;
          END IF;
        END IF;

        IF uid_text IS NULL AND raw_claims IS NOT NULL THEN
          uid_regex := regexp_replace(
            raw_claims,
            '.*"x-hasura-user-id"\\s*:\\s*"([^"]+)".*',
            '\\1'
          );
          IF uid_regex IS NOT NULL AND uid_regex <> raw_claims THEN
            uid_text := uid_regex;
          END IF;
        END IF;

        RETURN NULLIF(uid_text, '');
      END;
      $body$;
    $fn$;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Add group control flags to conversations
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    ALTER TABLE public.chat_conversations
      ADD COLUMN IF NOT EXISTS is_frozen boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS admins_only boolean NOT NULL DEFAULT false;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2) Ensure participant roles + soft-delete flags
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    ALTER TABLE public.chat_participants
      ADD COLUMN IF NOT EXISTS role text,
      ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
  END IF;
END $$;

-- Backfill roles for existing data
UPDATE public.chat_participants p
SET role = 'owner'
FROM public.chat_conversations c
WHERE p.conversation_id = c.id
  AND p.user_uid = c.created_by
  AND (p.role IS NULL OR btrim(p.role) = '');

UPDATE public.chat_participants
SET role = 'member'
WHERE role IS NULL OR btrim(role) = '' OR role NOT IN ('owner','admin','member');

DO $$
BEGIN
  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'chat_participants_role_chk'
    ) THEN
      ALTER TABLE public.chat_participants
        ADD CONSTRAINT chat_participants_role_chk
        CHECK (role IN ('owner','admin','member'));
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Delivery/Read cursor fields on chat_reads
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.chat_reads') IS NOT NULL THEN
    ALTER TABLE public.chat_reads
      ADD COLUMN IF NOT EXISTS last_read_message_id uuid,
      ADD COLUMN IF NOT EXISTS last_read_at timestamptz,
      ADD COLUMN IF NOT EXISTS last_delivered_message_id uuid,
      ADD COLUMN IF NOT EXISTS last_delivered_at timestamptz;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'chat_reads_last_delivered_message_id_fkey'
    ) THEN
      ALTER TABLE public.chat_reads
        ADD CONSTRAINT chat_reads_last_delivered_message_id_fkey
        FOREIGN KEY (last_delivered_message_id)
        REFERENCES public.chat_messages(id)
        ON DELETE SET NULL;
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4) Views: expose delivered fields + hide archived/deleted conversations
-- ---------------------------------------------------------------------------
DO $m$
BEGIN
  IF to_regclass('public.chat_reads') IS NOT NULL THEN
    EXECUTE $sql$
      CREATE OR REPLACE VIEW public.v_chat_reads_for_me AS
      SELECT
        r.conversation_id,
        r.last_read_message_id,
        r.last_read_at,
        r.last_delivered_message_id,
        r.last_delivered_at
      FROM public.chat_reads r
      WHERE r.user_uid = nullif(public.request_uid_text(), '')::uuid
    $sql$;

    EXECUTE 'REVOKE ALL ON TABLE public.v_chat_reads_for_me FROM PUBLIC';
    EXECUTE 'GRANT SELECT ON TABLE public.v_chat_reads_for_me TO PUBLIC';
  END IF;
END $m$;

DO $m$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    EXECUTE 'DROP VIEW IF EXISTS public.v_chat_conversations_for_me';
    EXECUTE $sql$
      CREATE OR REPLACE VIEW public.v_chat_conversations_for_me AS
      WITH mine AS (
        SELECT p.conversation_id
        FROM public.chat_participants p
        WHERE p.user_uid = nullif(public.request_uid_text(), '')::uuid
          AND coalesce(p.archived, false) = false
          AND coalesce(p.is_deleted, false) = false
      ),
      mine_created AS (
        SELECT c.id AS conversation_id
        FROM public.chat_conversations c
        WHERE c.created_by = nullif(public.request_uid_text(), '')::uuid
      ),
      mine_all AS (
        SELECT conversation_id FROM mine
        UNION
        SELECT conversation_id FROM mine_created
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
        c.is_frozen,
        c.admins_only,
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
      JOIN mine_all m
        ON m.conversation_id = c.id
      LEFT JOIN public.v_chat_last_message lm
        ON lm.conversation_id = c.id
      LEFT JOIN unread u
        ON u.conversation_id = c.id
      WHERE coalesce(c.is_deleted, false) = false
    $sql$;

    EXECUTE 'REVOKE ALL ON TABLE public.v_chat_conversations_for_me FROM PUBLIC';
    EXECUTE 'GRANT SELECT ON TABLE public.v_chat_conversations_for_me TO PUBLIC';
  END IF;
END $m$;

-- ---------------------------------------------------------------------------
-- 5) Helper: can a user send a message to a conversation?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_can_send(
  p_conversation_id uuid,
  p_user_uid uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_conversations c
    JOIN public.chat_participants p
      ON p.conversation_id = c.id
    WHERE c.id = p_conversation_id
      AND p.user_uid = p_user_uid
      AND coalesce(p.is_deleted, false) = false
      AND (
        (coalesce(c.is_frozen, false) = false AND coalesce(c.admins_only, false) = false)
        OR p.role IN ('owner','admin')
      )
  );
$$;
REVOKE ALL ON FUNCTION public.chat_can_send(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_can_send(uuid, uuid) TO PUBLIC;

-- ---------------------------------------------------------------------------
-- 6) Enforce frozen/admins_only at DB level for message inserts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_chat_messages_guard_send()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  IF NOT public.chat_can_send(NEW.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'chat is locked' USING errcode = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_messages_guard_send ON public.chat_messages;
CREATE TRIGGER chat_messages_guard_send
BEFORE INSERT ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.tg_chat_messages_guard_send();

-- ---------------------------------------------------------------------------
-- 7) Group admin management RPCs (v_rpc_result)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_group_set_title(
  p_conversation_id uuid,
  p_title text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT role INTO v_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = v_uid
    AND coalesce(is_deleted, false) = false
  LIMIT 1;

  IF v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.chat_conversations
     SET title = NULLIF(btrim(p_title), ''),
         updated_at = now()
   WHERE id = p_conversation_id;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, v_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_group_set_title(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_group_set_title(uuid, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.chat_group_set_frozen(
  p_conversation_id uuid,
  p_is_frozen boolean,
  p_admins_only boolean DEFAULT true
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT role INTO v_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = v_uid
    AND coalesce(is_deleted, false) = false
  LIMIT 1;

  IF v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.chat_conversations
     SET is_frozen = coalesce(p_is_frozen, false),
         admins_only = coalesce(p_admins_only, true),
         updated_at = now()
   WHERE id = p_conversation_id;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, v_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_group_set_frozen(uuid, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_group_set_frozen(uuid, boolean, boolean) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.chat_group_set_member_role(
  p_conversation_id uuid,
  p_target_uid uuid,
  p_role text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_role text;
  v_target_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT role INTO v_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = v_uid
    AND coalesce(is_deleted, false) = false
  LIMIT 1;

  IF v_role <> 'owner' THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT role INTO v_target_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = p_target_uid
  LIMIT 1;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'cannot change owner' USING errcode = '42501';
  END IF;

  IF p_role NOT IN ('admin','member') THEN
    RAISE EXCEPTION 'invalid role' USING errcode = '22000';
  END IF;

  UPDATE public.chat_participants
     SET role = p_role
   WHERE conversation_id = p_conversation_id
     AND user_uid = p_target_uid;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, p_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_group_set_member_role(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_group_set_member_role(uuid, uuid, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.chat_group_remove_member(
  p_conversation_id uuid,
  p_target_uid uuid
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_role text;
  v_target_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT role INTO v_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = v_uid
    AND coalesce(is_deleted, false) = false
  LIMIT 1;

  IF v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT role INTO v_target_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = p_target_uid
  LIMIT 1;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'cannot remove owner' USING errcode = '42501';
  END IF;

  UPDATE public.chat_participants
     SET is_deleted = true,
         deleted_at = now()
   WHERE conversation_id = p_conversation_id
     AND user_uid = p_target_uid;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, v_target_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_group_remove_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_group_remove_member(uuid, uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.chat_group_delete(
  p_conversation_id uuid
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT role INTO v_role
  FROM public.chat_participants
  WHERE conversation_id = p_conversation_id
    AND user_uid = v_uid
    AND coalesce(is_deleted, false) = false
  LIMIT 1;

  IF v_role NOT IN ('owner','admin') THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.chat_conversations
     SET is_deleted = true,
         deleted_at = now(),
         updated_at = now()
   WHERE id = p_conversation_id;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, v_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_group_delete(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_group_delete(uuid) TO PUBLIC;

-- ---------------------------------------------------------------------------
-- 8) Update chat_start_dm to set roles for participants
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_start_dm(p_other_uid uuid)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_me uuid;
  v_other uuid := p_other_uid;
  v_conv uuid;
  v_me_acc uuid;
  v_other_acc uuid;
  v_account_id uuid;
  v_other_is_super boolean := false;
BEGIN
  v_me := nullif(public.request_uid_text(), '')::uuid;
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF v_other IS NULL THEN
    RAISE EXCEPTION 'missing target';
  END IF;

  IF v_other = v_me THEN
    RAISE EXCEPTION 'cannot dm self';
  END IF;

  PERFORM 1 FROM auth.users u WHERE u.id = v_other;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'target not found';
  END IF;

  SELECT account_id INTO v_me_acc
  FROM public.account_users
  WHERE user_uid = v_me
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT account_id INTO v_other_acc
  FROM public.account_users
  WHERE user_uid = v_other
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_me_acc IS NOT NULL AND v_other_acc IS NOT NULL AND v_me_acc = v_other_acc THEN
    v_account_id := v_me_acc;
  ELSE
    v_account_id := NULL;
  END IF;

  IF to_regproc('public.fn_is_super_admin_email(text)') IS NOT NULL THEN
    SELECT COALESCE(public.fn_is_super_admin_email(u.email), false)
      INTO v_other_is_super
    FROM auth.users u
    WHERE u.id = v_other;
  ELSE
    v_other_is_super := false;
  END IF;

  IF v_other_is_super THEN
    IF public.fn_is_super_admin() THEN
      -- superadmin chatting with anyone is allowed
      NULL;
    ELSE
      -- allow only owners to initiate DM with superadmin
      IF NOT EXISTS (
        SELECT 1
        FROM public.account_users au
        WHERE au.user_uid = v_me
          AND lower(coalesce(au.role, '')) = 'owner'
          AND coalesce(au.disabled, false) = false
      ) THEN
        RAISE EXCEPTION 'superadmin dm forbidden';
      END IF;
    END IF;
  END IF;

  SELECT c.id INTO v_conv
  FROM public.chat_conversations c
  JOIN public.chat_participants p1
    ON p1.conversation_id = c.id AND p1.user_uid = v_me
  JOIN public.chat_participants p2
    ON p2.conversation_id = c.id AND p2.user_uid = v_other
  WHERE c.is_group = false
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF v_conv IS NULL THEN
    v_conv := gen_random_uuid();
    INSERT INTO public.chat_conversations(
      id, is_group, title, account_id, created_by, created_at, updated_at
    ) VALUES (
      v_conv, false, NULL, v_account_id, v_me, now(), now()
    );
  END IF;

  INSERT INTO public.chat_participants(
    conversation_id, user_uid, email, joined_at, role
  )
  VALUES
    (
      v_conv,
      v_me,
      (SELECT email FROM auth.users WHERE id = v_me),
      now(),
      'owner'
    ),
    (
      v_conv,
      v_other,
      (SELECT email FROM auth.users WHERE id = v_other),
      now(),
      'member'
    )
  ON CONFLICT (conversation_id, user_uid) DO UPDATE
    SET email = EXCLUDED.email,
        joined_at = EXCLUDED.joined_at,
        role = COALESCE(public.chat_participants.role, EXCLUDED.role);

  RETURN QUERY SELECT v_conv::uuid AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_start_dm(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_start_dm(uuid) TO PUBLIC;

-- ---------------------------------------------------------------------------
-- 9) Ensure chat_accept_invitation sets role = member
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
CREATE OR REPLACE FUNCTION public.chat_accept_invitation(p_invitation_id uuid)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := lower(
    coalesce(current_setting('request.jwt.claims', true)::json ->> 'email', '')
  );
  v_inv record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT inv.*, conv.account_id, conv.created_by
  INTO v_inv
  FROM public.chat_group_invitations inv
  JOIN public.chat_conversations conv ON conv.id = inv.conversation_id
  WHERE inv.id = p_invitation_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation not found' USING errcode = 'P0002';
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN QUERY SELECT false, 'invitation not pending', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF NOT (
    v_inv.invitee_uid = v_uid
    OR (
      v_inv.invitee_uid IS NULL
      AND v_inv.invitee_email IS NOT NULL
      AND lower(v_inv.invitee_email) = v_email
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.chat_group_invitations
     SET status = 'accepted',
         invitee_uid = coalesce(v_inv.invitee_uid, v_uid),
         responded_at = now(),
         response_note = NULL
   WHERE id = p_invitation_id;

  INSERT INTO public.chat_participants (conversation_id, user_uid, email, joined_at, role)
  VALUES (
    v_inv.conversation_id,
    v_uid,
    NULLIF(v_email, ''),
    now(),
    'member'
  )
  ON CONFLICT (conversation_id, user_uid) DO UPDATE
    SET email = EXCLUDED.email,
        joined_at = EXCLUDED.joined_at,
        role = COALESCE(public.chat_participants.role, EXCLUDED.role);

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_accept_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_accept_invitation(uuid) TO PUBLIC;

COMMIT;
