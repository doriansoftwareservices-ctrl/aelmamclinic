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
