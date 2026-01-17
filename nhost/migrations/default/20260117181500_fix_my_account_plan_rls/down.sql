CREATE OR REPLACE FUNCTION public.my_account_plan()
RETURNS SETOF public.v_my_account_plan
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  v_uid_text text;
  v_uid uuid;
  v_account uuid;
  v_plan text;
  v_end timestamptz;
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

  v_uid_text := COALESCE(
    hasura_user ->> 'x-hasura-user-id',
    claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
    claims ->> 'x-hasura-user-id',
    claims ->> 'sub'
  );

  BEGIN
    v_uid := NULLIF(v_uid_text, '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    RETURN QUERY SELECT 'free'::text AS plan_code, NULL::timestamptz AS plan_end_at;
    RETURN;
  END IF;

  SELECT au.account_id
    INTO v_account
  FROM public.account_users au
  WHERE au.user_uid = v_uid
    AND coalesce(au.disabled, false) = false
  ORDER BY CASE WHEN lower(coalesce(au.role,'')) IN ('owner','admin','superadmin') THEN 0 ELSE 1 END,
           au.created_at DESC
  LIMIT 1;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT 'free'::text AS plan_code, NULL::timestamptz AS plan_end_at;
    RETURN;
  END IF;

  SELECT s.plan_code, s.end_at
    INTO v_plan, v_end
  FROM public.account_subscriptions s
  JOIN public.subscription_plans p ON p.code = s.plan_code
  WHERE s.account_id = v_account
    AND s.status = 'active'
    AND (
      s.end_at IS NULL OR
      (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) > now()
    )
  ORDER BY s.created_at DESC
  LIMIT 1;

  RETURN QUERY SELECT COALESCE(v_plan, 'free')::text AS plan_code, v_end AS plan_end_at;
END;
$$;

REVOKE ALL ON FUNCTION public.my_account_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_plan() TO PUBLIC;
