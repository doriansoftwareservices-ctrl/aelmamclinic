BEGIN;

CREATE OR REPLACE FUNCTION public.chat_start_support()
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_me uuid := nullif(public.request_uid_text(), '')::uuid;
  v_me_acc uuid;
  v_me_role text;
  v_agent uuid;
  v_conv uuid;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  SELECT account_id, role
    INTO v_me_acc, v_me_role
  FROM public.account_users
  WHERE user_uid = v_me
    AND coalesce(disabled, false) = false
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT user_uid
    INTO v_agent
  FROM public.chat_support_agents
  WHERE is_active = true
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  IF v_agent IS NULL THEN
    RAISE EXCEPTION 'no active support agent';
  END IF;

  SELECT c.id INTO v_conv
  FROM public.chat_conversations c
  JOIN public.chat_participants p1 ON p1.conversation_id = c.id AND p1.user_uid = v_me
  JOIN public.chat_participants p2 ON p2.conversation_id = c.id AND p2.user_uid = v_agent
  WHERE coalesce(c.is_group, false) = false
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF v_conv IS NULL THEN
    v_conv := gen_random_uuid();
    INSERT INTO public.chat_conversations(
      id, is_group, title, account_id, created_by, created_at, updated_at
    ) VALUES (
      v_conv, false, NULL, v_me_acc, v_me, now(), now()
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
      CASE WHEN lower(coalesce(v_me_role, '')) IN ('owner','admin')
        THEN lower(v_me_role)
        ELSE 'member'
      END
    ),
    (
      v_conv,
      v_agent,
      (SELECT email FROM auth.users WHERE id = v_agent),
      now(),
      'admin'
    )
  ON CONFLICT (conversation_id, user_uid) DO UPDATE
    SET email = EXCLUDED.email,
        joined_at = EXCLUDED.joined_at,
        role = COALESCE(public.chat_participants.role, EXCLUDED.role);

  RETURN QUERY SELECT v_conv::uuid AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_start_support() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_start_support() TO PUBLIC;

COMMIT;
