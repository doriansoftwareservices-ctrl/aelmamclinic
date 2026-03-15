BEGIN;

-- Data backfills are intentionally not reverted.

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
  v_me_role text;
  v_other_role text;
  v_me_disabled boolean := false;
  v_other_disabled boolean := false;
  v_account_id uuid;
  v_other_is_super boolean := false;
  v_me_chat_role text := 'member';
  v_other_chat_role text := 'member';
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

  SELECT account_id, role, coalesce(disabled,false)
    INTO v_me_acc, v_me_role, v_me_disabled
  FROM public.account_users
  WHERE user_uid = v_me
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT account_id, role, coalesce(disabled,false)
    INTO v_other_acc, v_other_role, v_other_disabled
  FROM public.account_users
  WHERE user_uid = v_other
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_me_disabled THEN
    RAISE EXCEPTION 'sender disabled';
  END IF;

  IF v_other_disabled THEN
    RAISE EXCEPTION 'target disabled';
  END IF;

  IF v_me_role IS NULL THEN
    v_me_role := 'employee';
  END IF;

  IF v_other_role IS NULL THEN
    v_other_role := 'employee';
  END IF;

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

  IF lower(coalesce(v_me_role, '')) = 'employee'
     OR lower(coalesce(v_other_role, '')) = 'employee' THEN
    IF v_other_is_super THEN
      RAISE EXCEPTION 'superadmin dm forbidden';
    END IF;
    IF v_me_acc IS NULL OR v_other_acc IS NULL OR v_me_acc <> v_other_acc THEN
      RAISE EXCEPTION 'cross-account employee dm forbidden';
    END IF;
  END IF;

  IF v_other_is_super THEN
    IF public.fn_is_super_admin() THEN
      NULL;
    ELSE
      IF lower(coalesce(v_me_role, '')) NOT IN ('owner','admin') THEN
        RAISE EXCEPTION 'superadmin dm forbidden';
      END IF;
    END IF;
  END IF;

  IF lower(coalesce(v_me_role, '')) IN ('owner','admin') THEN
    v_me_chat_role := lower(v_me_role);
  END IF;
  IF v_other_is_super THEN
    v_other_chat_role := 'admin';
  ELSIF lower(coalesce(v_other_role, '')) IN ('owner','admin') THEN
    v_other_chat_role := lower(v_other_role);
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
      v_me_chat_role
    ),
    (
      v_conv,
      v_other,
      (SELECT email FROM auth.users WHERE id = v_other),
      now(),
      v_other_chat_role
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

CREATE OR REPLACE FUNCTION public.chat_admin_start_dm(target_email text)
RETURNS SETOF v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security = off
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid_text text;
  caller_uid uuid;
  caller_email text;
  v_role text;
  is_super boolean;
  normalized_email text := lower(coalesce(target_email, ''));
  target_uid uuid;
  target_account uuid;
  existing_conv uuid;
  conv_id uuid;
  now_ts timestamptz := now();
BEGIN
  IF raw_hasura_user IS NOT NULL AND raw_hasura_user <> '' THEN
    BEGIN
      hasura_user := raw_hasura_user::jsonb;
    EXCEPTION WHEN others THEN
      hasura_user := '{}'::jsonb;
    END;
  END IF;

  caller_uid_text := COALESCE(
    hasura_user ->> 'x-hasura-user-id',
    claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
    claims ->> 'x-hasura-user-id',
    claims ->> 'sub'
  );

  BEGIN
    caller_uid := NULLIF(caller_uid_text, '')::uuid;
  EXCEPTION WHEN others THEN
    caller_uid := NULL;
  END;

  caller_email := lower(
    COALESCE(
      hasura_user ->> 'x-hasura-user-email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'email',
      claims ->> 'email',
      ''
    )
  );

  v_role := NULLIF(
    COALESCE(
      hasura_user ->> 'x-hasura-role',
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-role',
      claims ->> 'x-hasura-role'
    ),
    ''
  );

  is_super := (v_role = 'superadmin') OR public.fn_is_super_admin();

  IF caller_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'target_email is required';
  END IF;

  IF NOT is_super THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO target_uid
  FROM auth.users
  WHERE lower(email) = normalized_email
  ORDER BY created_at DESC
  LIMIT 1;

  IF target_uid IS NULL THEN
    RAISE EXCEPTION 'target user not found' USING errcode = 'P0002';
  END IF;

  IF target_uid = caller_uid THEN
    RAISE EXCEPTION 'cannot start conversation with yourself';
  END IF;

  SELECT au.account_id
    INTO target_account
  FROM public.account_users au
  WHERE au.user_uid = target_uid
    AND coalesce(au.disabled, false) = false
  ORDER BY CASE WHEN lower(coalesce(au.role, '')) IN ('owner','admin','superadmin') THEN 0 ELSE 1 END,
           au.created_at DESC
  LIMIT 1;

  SELECT p.conversation_id
    INTO existing_conv
  FROM public.chat_participants p
  JOIN public.chat_participants p2
    ON p.conversation_id = p2.conversation_id
  JOIN public.chat_conversations c
    ON c.id = p.conversation_id
  WHERE p.user_uid = caller_uid
    AND p2.user_uid = target_uid
    AND coalesce(c.is_group, false) = false
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF existing_conv IS NOT NULL THEN
    RETURN QUERY SELECT existing_conv AS id;
    RETURN;
  END IF;

  conv_id := gen_random_uuid();

  INSERT INTO public.chat_conversations(id, account_id, is_group, title, created_by, created_at, updated_at)
  VALUES (conv_id, target_account, false, NULL, caller_uid, now_ts, now_ts);

  INSERT INTO public.chat_participants(conversation_id, user_uid, role, email, joined_at)
  VALUES
    (conv_id, caller_uid, 'superadmin', NULLIF(caller_email, ''), now_ts),
    (conv_id, target_uid, NULL, normalized_email, now_ts);

  RETURN QUERY SELECT conv_id AS id;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_admin_start_dm(text) FROM public;
GRANT EXECUTE ON FUNCTION public.chat_admin_start_dm(text) TO public;

COMMIT;
