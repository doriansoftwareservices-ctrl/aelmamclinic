--//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\supabase\migrations\20250901090100_rpc_my_account_id_and_my_accounts.sql
-- my_account_id() و my_accounts()
-- يوفّر account_id الافتراضي و/أو كل الحسابات المرتبطة بالمستخدم الحالي.

create or replace function public.my_account_id()
returns uuid
language sql
security definer
set search_path = public
as $$
  select account_id
  from public.account_users
  where user_uid = nullif(public.request_uid_text(), '')::uuid
    and coalesce(disabled, false) = false
  order by created_at desc
  limit 1;
$$;
revoke all on function public.my_account_id() from public;
grant execute on function public.my_account_id() TO public;
create or replace function public.my_accounts()
returns setof uuid
language sql
security definer
set search_path = public
as $$
  select account_id
  from public.account_users
  where user_uid = nullif(public.request_uid_text(), '')::uuid
    and coalesce(disabled, false) = false
  order by created_at desc;
$$;
revoke all on function public.my_accounts() from public;
grant execute on function public.my_accounts() TO public;
create or replace function public.my_profile()
returns table (
  id uuid,
  email text,
  role text,
  account_id uuid,
  display_name text,
  account_ids uuid[]
)
language sql
security definer
set search_path = public, auth
as $$
  with me as (
    select
      u.id,
      u.email,
      p.role as profile_role,
      p.account_id as profile_account_id,
      p.display_name,
      (
        select array_agg(au.account_id order by au.created_at desc)
        from public.account_users au
        where au.user_uid = u.id
          and coalesce(au.disabled, false) = false
      ) as membership_accounts,
      (
        select au.role
        from public.account_users au
        where au.user_uid = u.id
          and coalesce(au.disabled, false) = false
        order by au.created_at desc
        limit 1
      ) as membership_role
    from auth.users u
    left join public.profiles p on p.id = u.id
    where u.id = nullif(public.request_uid_text(), '')::uuid
  )
  select
    me.id,
    me.email,
    coalesce(me.profile_role, me.membership_role, 'employee') as role,
    coalesce(me.profile_account_id, me.membership_accounts[1], public.my_account_id()) as account_id,
    me.display_name,
    coalesce(me.membership_accounts, array[]::uuid[]) as account_ids
  from me;
$$;
revoke all on function public.my_profile() from public;
grant execute on function public.my_profile() TO public;
create or replace function public.my_feature_permissions(p_account uuid)
returns table (
  account_id uuid,
  allowed_features text[],
  can_create boolean,
  can_update boolean,
  can_delete boolean
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_allowed text[];
  v_can_create boolean;
  v_can_update boolean;
  v_can_delete boolean;
begin
  if v_uid is null then
    return;
  end if;

  if p_account is null then
    return query select null::uuid, array[]::text[], true, true, true;
  end if;

  if not v_is_super then
    if not exists (
      select 1
      from public.account_users au
      where au.account_id = p_account
        and au.user_uid = v_uid
        and coalesce(au.disabled, false) = false
    ) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  if not exists (
    select 1
    from information_schema.tables
    where table_schema = 'public' and table_name = 'account_feature_permissions'
  ) then
    return query select p_account, array[]::text[], true, true, true;
  end if;

  select
    afp.allowed_features,
    afp.can_create,
    afp.can_update,
    afp.can_delete
  into v_allowed, v_can_create, v_can_update, v_can_delete
  from public.account_feature_permissions afp
  where afp.account_id = p_account
    and (afp.user_uid = v_uid or afp.user_uid is null)
  order by case when afp.user_uid = v_uid then 0 else 1 end
  limit 1;

  return query select
    p_account,
    coalesce(v_allowed, array[]::text[]),
    coalesce(v_can_create, true),
    coalesce(v_can_update, true),
    coalesce(v_can_delete, true);
end;
$$;
revoke all on function public.my_feature_permissions(uuid) from public;
grant execute on function public.my_feature_permissions(uuid) TO public;
create or replace function public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_owner_uid uuid;
  v_account uuid;
begin
  if not v_is_super then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_clinic_name is null or length(trim(p_clinic_name)) = 0 then
    raise exception 'clinic_name is required';
  end if;

  if p_owner_email is null or length(trim(p_owner_email)) = 0 then
    raise exception 'owner_email is required';
  end if;

  select u.id
    into v_owner_uid
  from auth.users u
  where lower(u.email) = lower(p_owner_email)
  order by u.created_at desc
  limit 1;

  if v_owner_uid is null then
    raise exception 'owner with email % not found in auth.users', p_owner_email;
  end if;

  v_account := public.admin_bootstrap_clinic_for_email(p_clinic_name, p_owner_email, 'owner');

  return jsonb_build_object(
    'ok', true,
    'account_id', v_account,
    'owner_uid', v_owner_uid
  );
end;
$$;
revoke all on function public.admin_create_owner_full(text, text, text) from public;
grant execute on function public.admin_create_owner_full(text, text, text) TO public;
create or replace function public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_uid uuid;
begin
  if not v_is_super then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_account is null then
    raise exception 'account_id is required';
  end if;

  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'email is required';
  end if;

  if not exists (select 1 from public.accounts a where a.id = p_account) then
    raise exception 'account % not found', p_account;
  end if;

  select u.id
    into v_uid
  from auth.users u
  where lower(u.email) = lower(p_email)
  order by u.created_at desc
  limit 1;

  if v_uid is null then
    raise exception 'user with email % not found in auth.users', p_email;
  end if;

  perform public.admin_attach_employee(p_account, v_uid, 'employee');

  return jsonb_build_object(
    'ok', true,
    'account_id', p_account,
    'user_uid', v_uid
  );
end;
$$;
revoke all on function public.admin_create_employee_full(uuid, text, text) from public;
grant execute on function public.admin_create_employee_full(uuid, text, text) TO public;
create or replace function public.admin_list_clinics()
returns table (
  id uuid,
  name text,
  frozen boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
begin
  if not v_is_super then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    a.id,
    a.name,
    coalesce(a.frozen, false) as frozen,
    a.created_at
  from public.accounts a
  order by a.created_at desc;
end;
$$;
revoke all on function public.admin_list_clinics() from public;
grant execute on function public.admin_list_clinics() TO public;
create or replace function public.admin_set_clinic_frozen(
  p_account_id uuid,
  p_frozen boolean
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
begin
  if p_account_id is null then
    raise exception 'account_id is required';
  end if;

  if not v_is_super then
    if not exists (
      select 1
      from public.account_users au
      where au.account_id = p_account_id
        and au.user_uid = nullif(public.request_uid_text(), '')::uuid
        and coalesce(au.disabled, false) = false
        and lower(coalesce(au.role, '')) in ('owner', 'admin', 'superadmin')
    ) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  update public.accounts
     set frozen = coalesce(p_frozen, false)
   where id = p_account_id;

  if not found then
    raise exception 'account % not found', p_account_id;
  end if;
end;
$$;
revoke all on function public.admin_set_clinic_frozen(uuid, boolean) from public;
grant execute on function public.admin_set_clinic_frozen(uuid, boolean) TO public;
create or replace function public.admin_delete_clinic(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
begin
  if p_account_id is null then
    raise exception 'account_id is required';
  end if;

  if not v_is_super then
    if not exists (
      select 1
      from public.account_users au
      where au.account_id = p_account_id
        and au.user_uid = nullif(public.request_uid_text(), '')::uuid
        and coalesce(au.disabled, false) = false
        and lower(coalesce(au.role, '')) in ('owner', 'admin', 'superadmin')
    ) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  delete from public.accounts
  where id = p_account_id;

  if not found then
    raise exception 'account % not found', p_account_id;
  end if;
end;
$$;
revoke all on function public.admin_delete_clinic(uuid) from public;
grant execute on function public.admin_delete_clinic(uuid) TO public;
notify pgrst, 'reload schema';
