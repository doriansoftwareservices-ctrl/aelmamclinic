BEGIN;

CREATE TABLE IF NOT EXISTS public.chat_support_agents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_uid uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT 'خدمة العملاء',
  is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE UNIQUE INDEX IF NOT EXISTS chat_support_agents_user_uid_key
  ON public.chat_support_agents(user_uid);

CREATE UNIQUE INDEX IF NOT EXISTS chat_support_agents_one_active_idx
  ON public.chat_support_agents(is_active)
  WHERE is_active;

ALTER TABLE public.chat_support_agents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_support_agents_select_public ON public.chat_support_agents;
CREATE POLICY chat_support_agents_select_public
  ON public.chat_support_agents
  FOR SELECT
  TO "user"
  USING (is_active = true);

DROP POLICY IF EXISTS chat_support_agents_superadmin_all ON public.chat_support_agents;
CREATE POLICY chat_support_agents_superadmin_all
  ON public.chat_support_agents
  FOR ALL
  TO superadmin
  USING (true)
  WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.chat_support_agent()
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
  SELECT user_uid, display_name
  FROM public.chat_support_agents
  WHERE is_active = true
  ORDER BY updated_at DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.chat_set_support_agent(
  p_user_uid uuid,
  p_display_name text DEFAULT 'خدمة العملاء'
)
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
DECLARE
  v_uid uuid;
  v_name text;
BEGIN
  IF NOT public.fn_is_super_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_uid := p_user_uid;
  v_name := COALESCE(NULLIF(trim(p_display_name), ''), 'خدمة العملاء');

  UPDATE public.chat_support_agents
  SET is_active = false,
      updated_at = now()
  WHERE is_active = true;

  INSERT INTO public.chat_support_agents(
    user_uid,
    display_name,
    is_active,
    created_by,
    updated_at
  ) VALUES (
    v_uid,
    v_name,
    true,
    NULLIF(public.request_uid_text(), '')::uuid,
    now()
  )
  ON CONFLICT (user_uid)
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    is_active = true,
    updated_at = now();

  RETURN QUERY
  SELECT user_uid, display_name
  FROM public.chat_support_agents
  WHERE is_active = true
  ORDER BY updated_at DESC
  LIMIT 1;
END;
$$;

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
  v_other_roles text[];
  v_me_is_owner boolean := false;
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

  SELECT EXISTS(
    SELECT 1
    FROM public.account_users au
    WHERE au.user_uid = v_me
      AND coalesce(au.disabled, false) = false
      AND lower(coalesce(au.role, '')) = 'owner'
  ) INTO v_me_is_owner;

  IF to_regclass('auth.user_roles') IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM auth.user_roles ur
      WHERE ur.user_id = v_other AND ur.role = 'superadmin'
    ) INTO v_other_is_super;
  ELSE
    SELECT roles INTO v_other_roles
    FROM auth.users
    WHERE id = v_other;
    v_other_is_super := v_other_roles IS NOT NULL
      AND 'superadmin' = ANY(v_other_roles);
  END IF;

  IF v_other_is_super AND NOT (public.fn_is_super_admin() OR v_me_is_owner) THEN
    RAISE EXCEPTION 'superadmin dm forbidden';
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
    conversation_id, user_uid, email, joined_at
  )
  VALUES
    (
      v_conv,
      v_me,
      (SELECT email FROM auth.users WHERE id = v_me),
      now()
    ),
    (
      v_conv,
      v_other,
      (SELECT email FROM auth.users WHERE id = v_other),
      now()
    )
  ON CONFLICT (conversation_id, user_uid) DO UPDATE
    SET email = EXCLUDED.email,
        joined_at = EXCLUDED.joined_at;

  RETURN QUERY SELECT v_conv::uuid AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_start_dm(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_start_dm(uuid) TO PUBLIC;

COMMIT;
