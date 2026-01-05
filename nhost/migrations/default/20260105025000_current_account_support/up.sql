BEGIN;

-- Store the active account per user to support multi-account switching.
CREATE TABLE IF NOT EXISTS public.user_current_account (
  user_uid uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_current_account ENABLE ROW LEVEL SECURITY;

-- Keep updated_at fresh if helper exists.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'tg_touch_updated_at'
  ) THEN
    EXECUTE 'DROP TRIGGER IF EXISTS user_current_account_touch ON public.user_current_account';
    EXECUTE 'CREATE TRIGGER user_current_account_touch
      BEFORE UPDATE ON public.user_current_account
      FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at()';
  END IF;
END$$;

-- RLS: users can read/write only their own current account; superadmins can read/write all.
DROP POLICY IF EXISTS user_current_account_select_self ON public.user_current_account;
CREATE POLICY user_current_account_select_self
ON public.user_current_account
FOR SELECT
TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR user_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS user_current_account_insert_self ON public.user_current_account;
CREATE POLICY user_current_account_insert_self
ON public.user_current_account
FOR INSERT
TO PUBLIC
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = user_current_account.account_id
      AND au.user_uid = user_current_account.user_uid
      AND coalesce(au.disabled, false) = false
  )
);

DROP POLICY IF EXISTS user_current_account_update_self ON public.user_current_account;
CREATE POLICY user_current_account_update_self
ON public.user_current_account
FOR UPDATE
TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR user_uid = nullif(public.request_uid_text(), '')::uuid
)
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = user_current_account.account_id
      AND au.user_uid = user_current_account.user_uid
      AND coalesce(au.disabled, false) = false
  )
);

DROP POLICY IF EXISTS user_current_account_delete_self ON public.user_current_account;
CREATE POLICY user_current_account_delete_self
ON public.user_current_account
FOR DELETE
TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR user_uid = nullif(public.request_uid_text(), '')::uuid
);

-- RPC: set current account (upsert).
CREATE OR REPLACE FUNCTION public.set_current_account(
  hasura_session json,
  p_account uuid
)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id', '')::uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_account IS NULL THEN
    RAISE EXCEPTION 'account is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid = v_uid
      AND coalesce(au.disabled, false) = false
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.user_current_account(user_uid, account_id)
  VALUES (v_uid, p_account)
  ON CONFLICT (user_uid) DO UPDATE
    SET account_id = excluded.account_id,
        updated_at = now();

  RETURN QUERY SELECT p_account::uuid AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_current_account(json, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_current_account(json, uuid) TO PUBLIC;

-- Prefer current account when resolving my_account_id().
CREATE OR REPLACE FUNCTION public.my_account_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT uca.account_id
      FROM public.user_current_account uca
      WHERE uca.user_uid = nullif(public.request_uid_text(), '')::uuid
      LIMIT 1
    ),
    (
      SELECT au.account_id
      FROM public.account_users au
      WHERE au.user_uid = nullif(public.request_uid_text(), '')::uuid
      ORDER BY au.created_at DESC
      LIMIT 1
    )
  );
$$;
REVOKE ALL ON FUNCTION public.my_account_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id() TO PUBLIC;

-- my_profile: prefer current account role if set and active.
CREATE OR REPLACE FUNCTION public.my_profile(hasura_session json)
RETURNS SETOF public.v_my_profile
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
  WITH me AS (
    SELECT u.id, lower(u.email) AS email
    FROM auth.users u
    WHERE u.id = nullif(hasura_session->>'x-hasura-user-id','')::uuid
    LIMIT 1
  ),
  profile AS (
    SELECT p.id,
           p.role AS profile_role,
           p.account_id AS profile_account_id,
           p.display_name
    FROM public.profiles p
    JOIN me ON p.id = me.id
    LIMIT 1
  ),
  current_acc AS (
    SELECT uca.account_id
    FROM public.user_current_account uca
    JOIN me ON uca.user_uid = me.id
    LIMIT 1
  ),
  membership_latest AS (
    SELECT
      au.user_uid,
      (SELECT array_agg(au2.account_id ORDER BY au2.created_at DESC)
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
      ) AS account_ids,
      (SELECT au2.role
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
        ORDER BY au2.created_at DESC
        LIMIT 1
      ) AS role,
      (SELECT au2.account_id
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
        ORDER BY au2.created_at DESC
        LIMIT 1
      ) AS account_id
    FROM public.account_users au
    WHERE au.user_uid = (SELECT id FROM me)
    LIMIT 1
  ),
  membership_current AS (
    SELECT au.role, au.account_id
    FROM public.account_users au
    WHERE au.user_uid = (SELECT id FROM me)
      AND coalesce(au.disabled,false) = false
      AND au.account_id = (SELECT account_id FROM current_acc)
    LIMIT 1
  )
  SELECT
    me.id,
    me.email,
    CASE
      WHEN (SELECT is_super_admin FROM public.fn_is_super_admin_gql(hasura_session) LIMIT 1)
        THEN 'superadmin'
      ELSE coalesce(
        (SELECT role FROM membership_current),
        membership_latest.role,
        profile.profile_role,
        'employee'
      )
    END AS role,
    coalesce(
      (SELECT account_id FROM membership_current),
      membership_latest.account_id,
      profile.profile_account_id
    ) AS account_id,
    profile.display_name,
    coalesce(
      membership_latest.account_ids,
      CASE
        WHEN profile.profile_account_id IS NOT NULL
          THEN ARRAY[profile.profile_account_id]::uuid[]
        ELSE ARRAY[]::uuid[]
      END
    ) AS account_ids
  FROM me
  LEFT JOIN membership_latest ON membership_latest.user_uid = me.id
  LEFT JOIN profile ON profile.id = me.id;
$$;

COMMIT;
