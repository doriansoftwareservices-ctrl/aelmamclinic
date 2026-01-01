BEGIN;

-- Ensure allow_all exists.
ALTER TABLE public.account_feature_permissions
  ADD COLUMN IF NOT EXISTS allow_all boolean NOT NULL DEFAULT false;

-- Create default allow_all permissions for owners missing a row.
INSERT INTO public.account_feature_permissions (
  account_id,
  user_uid,
  allow_all,
  allowed_features,
  can_create,
  can_update,
  can_delete
)
SELECT
  au.account_id,
  au.user_uid,
  true,
  ARRAY[]::text[],
  true,
  true,
  true
FROM public.account_users au
WHERE au.role = 'owner'
  AND NOT EXISTS (
    SELECT 1
    FROM public.account_feature_permissions fp
    WHERE fp.account_id = au.account_id
      AND fp.user_uid = au.user_uid
  );

-- Backfill hook: ensure self_create_account seeds owner permissions.
CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
declare
  v_uid uuid := auth.uid();
  v_account uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;

  if p_clinic_name is null or btrim(p_clinic_name) = '' then
    raise exception 'p_clinic_name required';
  end if;

  if exists (
    select 1 from public.account_users au
    where au.user_uid = v_uid and au.role = 'owner'
  ) then
    raise exception 'account already exists for this user';
  end if;

  insert into public.accounts(name)
  values (p_clinic_name)
  returning id into v_account;

  insert into public.account_users(user_uid, account_id, role, disabled)
  values (v_uid, v_account, 'owner', false)
  on conflict (user_uid, account_id) do update
  set role = excluded.role,
      disabled = excluded.disabled;

  insert into public.profiles(id, email, role, account_id)
  select v_uid, u.email, 'owner', v_account
  from auth.users u
  where u.id = v_uid
  on conflict (id) do update
  set role = 'owner',
      account_id = v_account;

  -- Seed owner feature permissions (allow all)
  insert into public.account_feature_permissions(
    account_id,
    user_uid,
    allow_all,
    allowed_features,
    can_create,
    can_update,
    can_delete
  ) values (
    v_account,
    v_uid,
    true,
    ARRAY[]::text[],
    true,
    true,
    true
  )
  on conflict (account_id, user_uid) do update
  set allow_all = true,
      can_create = true,
      can_update = true,
      can_delete = true;

  perform public.auth_set_user_claims(v_uid, 'owner', v_account);

  return query select v_account::uuid as id;
end;
$$;

COMMIT;
