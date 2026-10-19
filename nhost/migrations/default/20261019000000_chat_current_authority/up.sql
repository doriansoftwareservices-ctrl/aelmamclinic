BEGIN;

-- This marker is private to the database. An old tombstone is deliberately not
-- inferred to be a personal hide: a removed member must never revive itself.
ALTER TABLE public.chat_participants
  ADD COLUMN personal_hidden boolean NOT NULL DEFAULT false;

-- Current authority is evaluated from the room, never a client-supplied clinic
-- or a participant's historical role. These views have no client select grant
-- in Hasura; metadata uses them only as permission relations.
CREATE VIEW public.chat_scope_authority WITH (security_barrier = true) AS
WITH eligible AS (
  SELECT c.id AS conversation_id, c.account_id, au.user_uid, false AS is_superadmin
  FROM public.chat_conversations c
  JOIN public.accounts a ON a.id = c.account_id AND a.frozen IS DISTINCT FROM true
  JOIN public.account_users au ON au.account_id = a.id
  WHERE au.disabled IS DISTINCT FROM true
  UNION ALL
  SELECT c.id, c.account_id, au.user_uid, false
  FROM public.chat_conversations c
  CROSS JOIN public.account_users au
  JOIN public.accounts a ON a.id = au.account_id AND a.frozen IS DISTINCT FROM true
  WHERE c.account_id IS NULL AND au.disabled IS DISTINCT FROM true
    AND lower(coalesce(au.role, '')) IN ('owner', 'admin')
  UNION ALL
  SELECT c.id, c.account_id, sa.user_uid, true
  FROM public.chat_conversations c
  CROSS JOIN public.active_superadmin_identity sa
  LEFT JOIN public.accounts a ON a.id = c.account_id
  WHERE c.account_id IS NULL OR (a.id IS NOT NULL AND a.frozen IS DISTINCT FROM true)
  UNION ALL
  -- A support assignment is a DB record plus the established support-room
  -- participant. A role header or assignment alone grants no other room.
  SELECT c.id, c.account_id, support.user_uid, false
  FROM public.chat_conversations c
  JOIN public.chat_participants p ON p.conversation_id = c.id
    AND p.account_id IS NULL AND p.role = 'admin'
    AND (p.is_deleted IS DISTINCT FROM true OR p.personal_hidden)
  JOIN public.chat_support_agents support ON support.user_uid = p.user_uid AND support.is_active
  LEFT JOIN public.accounts a ON a.id = c.account_id
  WHERE NOT c.is_group AND c.created_by <> p.user_uid
    AND (c.account_id IS NULL OR (a.id IS NOT NULL AND a.frozen IS DISTINCT FROM true))
)
SELECT e.conversation_id, e.account_id, e.user_uid,
       bool_or(e.is_superadmin) AS is_superadmin
FROM eligible e
JOIN public.chat_conversations c ON c.id = e.conversation_id
JOIN auth.users u ON u.id = e.user_uid AND u.disabled IS DISTINCT FROM true
WHERE c.is_deleted IS DISTINCT FROM true
GROUP BY e.conversation_id, e.account_id, e.user_uid;

CREATE VIEW public.chat_current_access WITH (security_barrier = true) AS
SELECT s.conversation_id, s.account_id, s.user_uid, s.is_superadmin,
       (s.is_superadmin OR
         (p.user_uid IS NOT NULL AND p.is_deleted IS DISTINCT FROM true)) AS can_read,
       (p.user_uid IS NOT NULL AND
         (p.is_deleted IS DISTINCT FROM true OR p.personal_hidden)) AS can_self_update,
       (c.created_by = s.user_uid AND p.user_uid IS NULL) AS can_bootstrap
FROM public.chat_scope_authority s
JOIN public.chat_conversations c ON c.id = s.conversation_id
LEFT JOIN public.chat_participants p
  ON p.conversation_id = s.conversation_id AND p.user_uid = s.user_uid;

-- Message-keyed surfaces (reactions) do not have a conversation_id column.
-- Correlate their root message_id directly, without ambiguous nested $ scopes.
CREATE VIEW public.chat_message_current_access WITH (security_barrier = true) AS
SELECT m.id AS message_id, a.conversation_id, a.user_uid, a.is_superadmin, a.can_read
FROM public.chat_messages m
JOIN public.chat_current_access a ON a.conversation_id = m.conversation_id;

CREATE FUNCTION public.chat_actor_has_scope(p_conversation_id uuid, p_actor_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
  SELECT EXISTS (SELECT 1 FROM public.chat_scope_authority a
    WHERE a.conversation_id = p_conversation_id AND a.user_uid = p_actor_uid);
$function$;
REVOKE ALL ON FUNCTION public.chat_actor_has_scope(uuid, uuid) FROM PUBLIC;

CREATE FUNCTION public.chat_actor_can_read(p_conversation_id uuid, p_actor_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
  SELECT EXISTS (SELECT 1 FROM public.chat_current_access a
    WHERE a.conversation_id = p_conversation_id AND a.user_uid = p_actor_uid AND a.can_read);
$function$;
REVOKE ALL ON FUNCTION public.chat_actor_can_read(uuid, uuid) FROM PUBLIC;

-- Existing RLS helper now uses the same authority as Hasura and the previews.
CREATE OR REPLACE FUNCTION public.chat_is_participant(p_conversation uuid, p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
  SELECT public.chat_actor_can_read(p_conversation, p_user);
$function$;

-- RLS must be able to authorize an unhide without granting hidden-room reads.
-- This helper accepts no actor argument and is not registered as a GraphQL RPC.
CREATE FUNCTION public.chat_self_service_allowed(p_conversation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
  SELECT EXISTS (SELECT 1 FROM public.chat_current_access a
    WHERE a.conversation_id = p_conversation_id
      AND a.user_uid = nullif(public.request_uid_text(), '')::uuid AND a.can_self_update);
$function$;
REVOKE ALL ON FUNCTION public.chat_self_service_allowed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_self_service_allowed(uuid) TO PUBLIC;

CREATE FUNCTION public.chat_bootstrap_allowed(p_conversation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
  SELECT EXISTS (SELECT 1 FROM public.chat_current_access a
    WHERE a.conversation_id = p_conversation_id
      AND a.user_uid = nullif(public.request_uid_text(), '')::uuid AND a.can_bootstrap);
$function$;
REVOKE ALL ON FUNCTION public.chat_bootstrap_allowed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_bootstrap_allowed(uuid) TO PUBLIC;

DROP POLICY IF EXISTS chat_conversations_select ON public.chat_conversations;
CREATE POLICY chat_conversations_select ON public.chat_conversations FOR SELECT USING (
  public.chat_is_participant(id, nullif(public.request_uid_text(), '')::uuid)
  OR public.chat_bootstrap_allowed(id));

DROP POLICY IF EXISTS chat_participants_select ON public.chat_participants;
CREATE POLICY chat_participants_select ON public.chat_participants FOR SELECT USING (
  public.chat_is_participant(conversation_id, nullif(public.request_uid_text(), '')::uuid)
  OR (user_uid = nullif(public.request_uid_text(), '')::uuid
      AND (public.chat_self_service_allowed(conversation_id) OR public.chat_bootstrap_allowed(conversation_id))));
DROP POLICY IF EXISTS chat_participants_update ON public.chat_participants;
CREATE POLICY chat_participants_update ON public.chat_participants FOR UPDATE USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND public.chat_self_service_allowed(conversation_id)) WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND public.chat_self_service_allowed(conversation_id));

DROP POLICY IF EXISTS chat_typing_select_member ON public.chat_typing;
CREATE POLICY chat_typing_select_member ON public.chat_typing FOR SELECT USING (
  public.chat_is_participant(conversation_id, nullif(public.request_uid_text(), '')::uuid));
DROP POLICY IF EXISTS chat_typing_manage_self ON public.chat_typing;
CREATE POLICY chat_typing_manage_self ON public.chat_typing FOR ALL USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND public.chat_is_participant(conversation_id, nullif(public.request_uid_text(), '')::uuid)) WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND public.chat_is_participant(conversation_id, nullif(public.request_uid_text(), '')::uuid));

-- Retain earlier receipt rules, adding a restrictive authority condition so
-- their inline historical participant test cannot keep a revoked member alive.
CREATE POLICY chat_delivery_current_scope ON public.chat_delivery_receipts
AS RESTRICTIVE FOR ALL USING (
  public.chat_is_participant(conversation_id, nullif(public.request_uid_text(), '')::uuid))
WITH CHECK (public.chat_is_participant(conversation_id, nullif(public.request_uid_text(), '')::uuid));

CREATE OR REPLACE FUNCTION public.chat_can_send(p_conversation_id uuid, p_user_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
  SELECT public.chat_actor_can_read(p_conversation_id, p_user_uid) AND EXISTS (
    SELECT 1 FROM public.chat_conversations c
    JOIN public.chat_participants p ON p.conversation_id = c.id
    WHERE c.id = p_conversation_id AND p.user_uid = p_user_uid
      AND p.is_deleted IS DISTINCT FROM true
      AND ((NOT coalesce(c.is_frozen, false) AND NOT coalesce(c.admins_only, false))
           OR p.role IN ('owner', 'admin', 'superadmin')));
$function$;

-- Lock the actual authority rows before a chat write. Revocation committed
-- before this lock is observed; a concurrent revoker waits for the write to end.
CREATE FUNCTION public.chat_lock_actor_scope(p_conversation_id uuid, p_actor_uid uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_temp AS $function$
BEGIN
  PERFORM 1 FROM auth.users WHERE id = p_actor_uid FOR SHARE;
  PERFORM 1 FROM public.chat_conversations WHERE id = p_conversation_id FOR SHARE;
  PERFORM 1 FROM public.chat_participants
    WHERE conversation_id = p_conversation_id AND user_uid = p_actor_uid FOR SHARE;
  PERFORM 1 FROM public.account_users WHERE user_uid = p_actor_uid
    ORDER BY account_id FOR SHARE;
  PERFORM 1 FROM public.accounts WHERE id IN (
    SELECT account_id FROM public.account_users WHERE user_uid = p_actor_uid
    UNION SELECT account_id FROM public.chat_conversations WHERE id = p_conversation_id
  ) ORDER BY id FOR SHARE;
  PERFORM 1 FROM public.super_admins WHERE user_uid = p_actor_uid FOR SHARE;
  PERFORM 1 FROM public.chat_support_agents WHERE user_uid = p_actor_uid FOR SHARE;
  IF p_conversation_id IS NOT NULL AND NOT public.chat_actor_has_scope(p_conversation_id, p_actor_uid) THEN
    RAISE EXCEPTION 'chat_current_authority_required' USING ERRCODE = '42501';
  END IF;
END;
$function$;
REVOKE ALL ON FUNCTION public.chat_lock_actor_scope(uuid, uuid) FROM PUBLIC;

CREATE FUNCTION public.tg_chat_conversation_creation_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_temp AS $function$
DECLARE actor uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF actor IS NULL THEN RETURN NEW; END IF;
  PERFORM public.chat_lock_actor_scope(NULL, actor);
  PERFORM 1 FROM public.accounts WHERE id = NEW.account_id FOR SHARE;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = actor AND disabled IS DISTINCT FROM true)
     OR NEW.created_by <> actor
     OR (NEW.account_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.accounts WHERE id = NEW.account_id AND frozen IS DISTINCT FROM true))
     OR NOT (EXISTS (SELECT 1 FROM public.active_superadmin_identity WHERE user_uid = actor)
       OR EXISTS (SELECT 1 FROM public.account_users au
         JOIN public.accounts a ON a.id = au.account_id AND a.frozen IS DISTINCT FROM true
         WHERE au.user_uid = actor AND au.disabled IS DISTINCT FROM true
           AND (au.account_id = NEW.account_id
             OR (NEW.account_id IS NULL AND lower(coalesce(au.role, '')) IN ('owner', 'admin'))))) THEN
    RAISE EXCEPTION 'chat_conversation_current_scope_required' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER chat_conversation_creation_guard BEFORE INSERT ON public.chat_conversations
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_conversation_creation_guard();

CREATE FUNCTION public.tg_chat_participant_current_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_temp AS $function$
DECLARE
  actor uuid := nullif(public.request_uid_text(), '')::uuid;
  room public.chat_conversations%ROWTYPE;
  removal boolean := coalesce(current_setting('elmam.chat_member_removal', true), '') = 'yes';
  actor_admin boolean;
  target_super boolean;
  target_support boolean;
  existing_self_service boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND (
    NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
    NEW.user_uid IS DISTINCT FROM OLD.user_uid OR
    NEW.account_id IS DISTINCT FROM OLD.account_id
  ) THEN
    RAISE EXCEPTION 'chat_participant_identity_is_immutable' USING ERRCODE = '42501';
  END IF;
  IF actor IS NOT NULL THEN
    PERFORM public.chat_lock_actor_scope(NEW.conversation_id, actor);
  END IF;
  SELECT * INTO room FROM public.chat_conversations WHERE id = NEW.conversation_id;
  SELECT EXISTS (SELECT 1 FROM public.active_superadmin_identity WHERE user_uid = NEW.user_uid)
    INTO target_super;
  SELECT EXISTS (SELECT 1 FROM public.chat_support_agents s
    JOIN auth.users u ON u.id = s.user_uid
    WHERE s.user_uid = NEW.user_uid AND s.is_active AND u.disabled IS DISTINCT FROM true
      AND NOT room.is_group AND NEW.role = 'admin' AND room.created_by <> NEW.user_uid)
    INTO target_support;
  IF NEW.account_id IS DISTINCT FROM room.account_id
     AND NOT (NEW.account_id IS NULL AND (target_super OR target_support)) THEN
    RAISE EXCEPTION 'chat_participant_scope_mismatch' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NOT public.chat_actor_has_scope(NEW.conversation_id, NEW.user_uid)
       AND NOT (target_support AND actor = room.created_by) THEN
      RAISE EXCEPTION 'chat_participant_current_scope_required' USING ERRCODE = '42501';
    END IF;
    -- BEFORE INSERT also runs for ON CONFLICT UPDATE. Existing DM/support RPCs
    -- refresh both participants' email/joined_at when either member reopens a
    -- room; that is not a new self-join. The UPDATE guard still checks the real
    -- changed columns and rejects identity/role mutation or removed-member revival.
    SELECT EXISTS (SELECT 1 FROM public.chat_participants p
      WHERE p.conversation_id = NEW.conversation_id AND p.user_uid = NEW.user_uid
        AND (p.is_deleted IS DISTINCT FROM true OR p.personal_hidden)) INTO existing_self_service;
    IF existing_self_service THEN
      IF actor IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.chat_current_access a
        WHERE a.conversation_id = NEW.conversation_id AND a.user_uid = actor
          AND (a.can_read OR a.can_self_update)) THEN
        RAISE EXCEPTION 'chat_existing_participant_requires_current_actor' USING ERRCODE = '42501';
      END IF;
      NEW.personal_hidden := false;
      RETURN NEW;
    END IF;
    IF actor IS NOT NULL AND actor = NEW.user_uid AND room.created_by <> actor
       AND NOT target_super THEN
      RAISE EXCEPTION 'chat_participant_direct_self_join_forbidden' USING ERRCODE = '42501';
    END IF;
    IF actor IS NOT NULL AND actor <> room.created_by
       AND NOT EXISTS (SELECT 1 FROM public.active_superadmin_identity WHERE user_uid = actor) THEN
      RAISE EXCEPTION 'chat_participant_creator_required' USING ERRCODE = '42501';
    END IF;
    NEW.personal_hidden := false;
    RETURN NEW;
  END IF;
  IF actor IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.chat_current_access a
      JOIN public.chat_participants p ON p.conversation_id = a.conversation_id AND p.user_uid = a.user_uid
      WHERE a.conversation_id = NEW.conversation_id AND a.user_uid = actor AND a.can_read
        AND (a.is_superadmin OR p.role IN ('owner', 'admin'))) INTO actor_admin;
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      IF actor = NEW.user_uid OR NOT actor_admin OR OLD.role = 'owner'
         OR NOT EXISTS (SELECT 1 FROM public.chat_participants p WHERE p.conversation_id = NEW.conversation_id
           AND p.user_uid = actor AND p.role = 'owner' AND p.is_deleted IS DISTINCT FROM true) THEN
        RAISE EXCEPTION 'chat_participant_role_change_forbidden' USING ERRCODE = '42501';
      END IF;
    END IF;
    IF actor = NEW.user_uid AND OLD.is_deleted AND NOT OLD.personal_hidden THEN
      RAISE EXCEPTION 'chat_removed_participant_is_not_self_service' USING ERRCODE = '42501';
    END IF;
    IF actor <> NEW.user_uid AND NOT actor_admin AND NOT (
      (to_jsonb(NEW) - ARRAY['email', 'joined_at']) IS NOT DISTINCT FROM
        (to_jsonb(OLD) - ARRAY['email', 'joined_at'])
      AND EXISTS (SELECT 1 FROM public.chat_current_access a
        WHERE a.conversation_id = NEW.conversation_id AND a.user_uid = actor
          AND (a.can_read OR a.can_self_update))
    ) THEN
      RAISE EXCEPTION 'chat_participant_admin_required' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF NEW.is_deleted THEN
    IF removal THEN
      NEW.personal_hidden := false;
    ELSIF NEW.is_deleted IS NOT DISTINCT FROM OLD.is_deleted THEN
      -- Reopening a DM refreshes the other participant's email/joined_at too.
      -- That refresh must not convert their existing personal hide to removal.
      NEW.personal_hidden := OLD.personal_hidden;
    ELSIF actor IS DISTINCT FROM NEW.user_uid THEN
      NEW.personal_hidden := false;
    ELSIF NOT OLD.is_deleted THEN
      NEW.personal_hidden := true;
    ELSE
      NEW.personal_hidden := OLD.personal_hidden;
    END IF;
  ELSE
    NEW.personal_hidden := false;
    NEW.deleted_at := NULL;
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER chat_participant_current_guard BEFORE INSERT OR UPDATE ON public.chat_participants
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_participant_current_guard();

CREATE FUNCTION public.tg_chat_conversation_identity_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE actor uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.is_group IS DISTINCT FROM OLD.is_group THEN
    RAISE EXCEPTION 'chat_conversation_identity_is_immutable' USING ERRCODE = '42501';
  END IF;
  IF actor IS NOT NULL THEN
    PERFORM public.chat_lock_actor_scope(OLD.id, actor);
    IF NOT public.chat_actor_can_read(OLD.id, actor) THEN
      RAISE EXCEPTION 'chat_conversation_current_member_required' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER chat_conversation_identity_guard BEFORE UPDATE ON public.chat_conversations
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_conversation_identity_guard();

CREATE FUNCTION public.tg_chat_message_current_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE
  actor uuid := nullif(public.request_uid_text(), '')::uuid;
  room_id uuid;
  sender uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN room_id := OLD.conversation_id; sender := OLD.sender_uid;
  ELSE room_id := NEW.conversation_id; sender := NEW.sender_uid; END IF;
  IF actor IS NOT NULL THEN
    PERFORM public.chat_lock_actor_scope(room_id, actor);
    IF NOT public.chat_actor_can_read(room_id, actor) OR
       (sender <> actor AND NOT EXISTS (SELECT 1 FROM public.active_superadmin_identity WHERE user_uid = actor)) THEN
      RAISE EXCEPTION 'chat_message_current_member_required' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER chat_message_current_guard BEFORE INSERT OR UPDATE OR DELETE ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_message_current_guard();

CREATE FUNCTION public.tg_chat_participant_delete_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE actor uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF actor IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.active_superadmin_identity WHERE user_uid = actor) THEN
    RAISE EXCEPTION 'chat_participant_removal_requires_tombstone' USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$function$;
CREATE TRIGGER chat_participant_delete_guard BEFORE DELETE ON public.chat_participants
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_participant_delete_guard();

CREATE FUNCTION public.tg_chat_state_current_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE actor uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF actor IS NOT NULL THEN
      PERFORM public.chat_lock_actor_scope(OLD.conversation_id, actor);
      IF OLD.user_uid <> actor OR NOT public.chat_actor_can_read(OLD.conversation_id, actor) THEN
        RAISE EXCEPTION 'chat_state_current_member_required' USING ERRCODE = '42501';
      END IF;
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
    OR NEW.user_uid IS DISTINCT FROM OLD.user_uid
    OR (TG_TABLE_NAME = 'chat_reads' AND (to_jsonb(NEW)->'account_id') IS DISTINCT FROM (to_jsonb(OLD)->'account_id'))
    OR (TG_TABLE_NAME = 'chat_delivery_receipts' AND (to_jsonb(NEW)->'message_id') IS DISTINCT FROM (to_jsonb(OLD)->'message_id'))) THEN
    RAISE EXCEPTION 'chat_state_identity_is_immutable' USING ERRCODE = '42501';
  END IF;
  IF actor IS NOT NULL THEN
    PERFORM public.chat_lock_actor_scope(NEW.conversation_id, actor);
    IF NEW.user_uid <> actor OR NOT public.chat_actor_can_read(NEW.conversation_id, actor) THEN
      RAISE EXCEPTION 'chat_state_current_member_required' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'chat_reads' THEN
    IF NEW.account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.chat_conversations c
      WHERE c.id = NEW.conversation_id AND c.account_id = NEW.account_id) THEN
      RAISE EXCEPTION 'chat_read_account_scope_mismatch' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM public.chat_messages m
      WHERE m.id IN (NEW.last_read_message_id, NEW.last_delivered_message_id)
        AND m.conversation_id <> NEW.conversation_id) THEN
      RAISE EXCEPTION 'chat_read_cursor_scope_mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'chat_delivery_receipts' THEN
    IF EXISTS (SELECT 1 FROM public.chat_messages m
      WHERE m.id = NEW.message_id AND m.conversation_id <> NEW.conversation_id) THEN
      RAISE EXCEPTION 'chat_delivery_message_scope_mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
CREATE TRIGGER chat_reads_current_guard BEFORE INSERT OR UPDATE OR DELETE ON public.chat_reads
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_state_current_guard();
CREATE TRIGGER chat_typing_current_guard BEFORE INSERT OR UPDATE OR DELETE ON public.chat_typing
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_state_current_guard();
CREATE TRIGGER chat_delivery_current_guard BEFORE INSERT OR UPDATE OR DELETE ON public.chat_delivery_receipts
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_state_current_guard();

-- Existing group removal keeps its signature and tracking state. Its context
-- flag is transaction-local and restored before returning, including exceptions.
DO $existing_rpc$
BEGIN
IF to_regprocedure('public.chat_group_remove_member(uuid,uuid)') IS NOT NULL THEN
EXECUTE $definition$
CREATE OR REPLACE FUNCTION public.chat_group_remove_member(p_conversation_id uuid, p_target_uid uuid)
RETURNS SETOF public.v_rpc_result LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE
  actor uuid := nullif(public.request_uid_text(), '')::uuid;
  actor_role text;
  target_role text;
  prior text := current_setting('elmam.chat_member_removal', true);
BEGIN
  PERFORM public.chat_lock_actor_scope(p_conversation_id, actor);
  SELECT p.role INTO actor_role FROM public.chat_participants p
    WHERE p.conversation_id = p_conversation_id AND p.user_uid = actor
      AND p.is_deleted IS DISTINCT FROM true FOR UPDATE;
  IF actor_role IS NULL OR actor_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  SELECT p.role INTO target_role FROM public.chat_participants p
    WHERE p.conversation_id = p_conversation_id AND p.user_uid = p_target_uid FOR UPDATE;
  IF target_role = 'owner' THEN
    RAISE EXCEPTION 'cannot remove owner' USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('elmam.chat_member_removal', 'yes', true);
  UPDATE public.chat_participants SET is_deleted = true, deleted_at = now()
    WHERE conversation_id = p_conversation_id AND user_uid = p_target_uid;
  PERFORM set_config('elmam.chat_member_removal', coalesce(prior, ''), true);
  RETURN QUERY SELECT true, NULL::text, NULL::uuid, actor, NULL::uuid, target_role, NULL::boolean, NULL::boolean;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('elmam.chat_member_removal', coalesce(prior, ''), true);
  RAISE;
END;
$function$;
$definition$;
END IF;
END;
$existing_rpc$;

-- A previously global DM/support room must not be reused after the caller's
-- current clinic scope changes. Keep each existing RPC and its grants; patch
-- only its room lookup, without creating any dropped/group RPC.
DO $scope_lookup$
DECLARE definition text;
BEGIN
  IF to_regprocedure('public.chat_start_dm(uuid)') IS NOT NULL THEN
    SELECT pg_get_functiondef('public.chat_start_dm(uuid)'::regprocedure) INTO definition;
    IF position('WHERE c.is_group = false' IN definition) = 0 THEN
      RAISE EXCEPTION 'chat_start_dm_lookup_contract_changed';
    END IF;
    EXECUTE replace(definition, 'WHERE c.is_group = false',
      'WHERE c.is_group = false AND c.account_id IS NOT DISTINCT FROM v_account_id');
  END IF;
  IF to_regprocedure('public.chat_start_support()') IS NOT NULL THEN
    SELECT pg_get_functiondef('public.chat_start_support()'::regprocedure) INTO definition;
    IF position('WHERE coalesce(c.is_group, false) = false' IN definition) = 0 THEN
      RAISE EXCEPTION 'chat_start_support_lookup_contract_changed';
    END IF;
    EXECUTE replace(definition, 'WHERE coalesce(c.is_group, false) = false',
      'WHERE coalesce(c.is_group, false) = false AND c.account_id IS NOT DISTINCT FROM v_me_acc');
  END IF;
  IF to_regprocedure('public.chat_admin_start_dm(text)') IS NOT NULL THEN
    SELECT pg_get_functiondef('public.chat_admin_start_dm(text)'::regprocedure) INTO definition;
    IF position('is_super := (v_role = ''superadmin'') OR public.fn_is_super_admin();' IN definition) = 0
       OR position('WHERE p.user_uid = caller_uid' IN definition) = 0 THEN
      RAISE EXCEPTION 'chat_admin_start_dm_authority_contract_changed';
    END IF;
    -- The JWT role names the API shape; only the current DB registry grants
    -- administrative authority. Preserve fn_is_super_admin's service path.
    definition := replace(definition,
      'is_super := (v_role = ''superadmin'') OR public.fn_is_super_admin();',
      'is_super := public.fn_is_super_admin();');
    EXECUTE replace(definition, 'WHERE p.user_uid = caller_uid',
      'WHERE c.account_id IS NOT DISTINCT FROM target_account AND p.user_uid = caller_uid');
  END IF;
END;
$scope_lookup$;

-- A current read authority is also required by all SQL previews. Preserve the
-- existing projections (including support status), cursors and unread rules.
CREATE OR REPLACE VIEW public.v_chat_last_message AS
SELECT c.id AS conversation_id, lm.id AS last_message_id,
  lm.kind AS last_message_kind, lm.body AS last_message_body,
  lm.created_at AS last_message_created_at
FROM public.chat_conversations c
LEFT JOIN LATERAL (
  SELECT m.id, m.kind, m.body, m.created_at FROM public.chat_messages m
  WHERE m.conversation_id = c.id AND m.deleted IS DISTINCT FROM true AND m.is_deleted IS DISTINCT FROM true
  ORDER BY m.created_at DESC, m.id DESC LIMIT 1
) lm ON true
WHERE (nullif(public.request_uid_text(), '') IS NULL OR EXISTS (
  SELECT 1 FROM public.chat_current_access a WHERE a.conversation_id = c.id
  AND a.user_uid = nullif(public.request_uid_text(), '')::uuid AND a.can_read));

CREATE OR REPLACE VIEW public.v_chat_reads_for_me AS
SELECT r.conversation_id, r.last_read_message_id, r.last_read_at,
  r.last_delivered_message_id, r.last_delivered_at, r.user_uid
FROM public.chat_reads r
WHERE (nullif(public.request_uid_text(), '') IS NULL OR
       r.user_uid = nullif(public.request_uid_text(), '')::uuid)
  AND (nullif(public.request_uid_text(), '') IS NULL OR EXISTS (
      SELECT 1 FROM public.chat_current_access a WHERE a.conversation_id = r.conversation_id
      AND a.user_uid = r.user_uid AND a.can_read));

CREATE OR REPLACE VIEW public.v_chat_typing_active AS
SELECT t.conversation_id, t.user_uid, t.email, t.updated_at
FROM public.chat_typing t WHERE t.typing AND t.updated_at > now() - interval '15 seconds'
  AND (nullif(public.request_uid_text(), '') IS NULL OR EXISTS (
    SELECT 1 FROM public.chat_current_access a WHERE a.conversation_id = t.conversation_id
    AND a.user_uid = nullif(public.request_uid_text(), '')::uuid AND a.can_read));

-- The optional historical attachment projection can differ by installed
-- schema. Keep every existing column and aggregation, adding the common guard.
DO $existing_view$
DECLARE definition text;
BEGIN
  IF to_regclass('public.v_chat_messages_with_attachments') IS NOT NULL THEN
    SELECT rtrim(pg_get_viewdef('public.v_chat_messages_with_attachments'::regclass, true), '; ')
      INTO definition;
    EXECUTE 'CREATE OR REPLACE VIEW public.v_chat_messages_with_attachments AS SELECT original.* FROM ('
      || definition || ') original WHERE EXISTS (SELECT 1 FROM public.chat_current_access authority'
      || ' WHERE authority.conversation_id = original.conversation_id'
      || ' AND authority.user_uid = nullif(public.request_uid_text(), '''')::uuid AND authority.can_read)';
  END IF;
END;
$existing_view$;

CREATE OR REPLACE VIEW public.v_chat_conversations_for_me AS
SELECT c.id, c.account_id, c.is_group, c.is_frozen, c.admins_only, c.support_status,
  c.title, c.created_by, c.created_at, c.updated_at, c.last_msg_at, c.last_msg_snippet,
  lm.last_message_id, lm.last_message_kind, lm.last_message_body, lm.last_message_created_at,
  r.last_read_at,
  (SELECT count(*)::integer FROM public.chat_messages m WHERE m.conversation_id = c.id
    AND m.deleted IS DISTINCT FROM true AND m.is_deleted IS DISTINCT FROM true
    AND m.sender_uid IS DISTINCT FROM a.user_uid
    AND (r.last_read_at IS NULL OR m.created_at > r.last_read_at)) AS unread_count,
  CASE WHEN lm.last_message_kind = 'image' THEN 'image'
    WHEN lm.last_message_body IS NULL OR btrim(lm.last_message_body) = '' THEN NULL
    WHEN char_length(lm.last_message_body) > 64 THEN substr(lm.last_message_body, 1, 64) || '...'
    ELSE lm.last_message_body END AS last_message_text,
  a.user_uid
FROM public.chat_conversations c
JOIN public.chat_current_access a ON a.conversation_id = c.id AND a.can_read
LEFT JOIN public.v_chat_last_message lm ON lm.conversation_id = c.id
LEFT JOIN public.chat_reads r ON r.conversation_id = c.id AND r.user_uid = a.user_uid
WHERE (nullif(public.request_uid_text(), '') IS NULL
       OR a.user_uid = nullif(public.request_uid_text(), '')::uuid)
  AND NOT EXISTS (
    SELECT 1 FROM public.chat_participants p
    WHERE p.conversation_id = c.id AND p.user_uid = a.user_uid AND coalesce(p.archived, false));

-- Attachment Functions/claim consume this private contract. Support remains
-- support, never an implicit clinic administrator for another sender's file.
CREATE OR REPLACE FUNCTION public.chat_attachment_access_context(p_conversation_id uuid, p_actor_uid uuid)
RETURNS TABLE (account_id uuid, participant_role text, allowed boolean,
  is_superadmin boolean, account_frozen boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth, pg_temp AS $function$
  SELECT c.account_id,
    CASE WHEN support.user_uid IS NOT NULL AND p.account_id IS NULL AND p.role = 'admin'
           AND NOT c.is_group AND c.created_by <> p_actor_uid
           AND NOT coalesce(access.is_superadmin, false) THEN 'support'
         ELSE coalesce(p.role, '') END,
    coalesce(access.can_read, false), coalesce(access.is_superadmin, false), coalesce(a.frozen, false)
  FROM public.chat_conversations c
  LEFT JOIN public.accounts a ON a.id = c.account_id
  LEFT JOIN public.chat_participants p ON p.conversation_id = c.id AND p.user_uid = p_actor_uid
    AND p.is_deleted IS DISTINCT FROM true
  -- Keep a historical support participant classified as support if its
  -- assignment is disabled but the user separately retains clinic membership.
  -- Revoking support must never turn its stale role='admin' into file authority.
  LEFT JOIN public.chat_support_agents support ON support.user_uid = p_actor_uid
  LEFT JOIN public.chat_current_access access ON access.conversation_id = c.id AND access.user_uid = p_actor_uid
  WHERE c.id = p_conversation_id;
$function$;
REVOKE ALL ON FUNCTION public.chat_attachment_access_context(uuid, uuid) FROM PUBLIC;

COMMIT;
