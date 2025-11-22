-- 20251123031000_membership_functions_rls_off.sql
-- Ensures membership helper RPCs bypass account_users RLS entirely to avoid
-- recursion/timeouts when validating accounts or listing employees.

create or replace function public.my_account_id()
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  result uuid;
begin
  execute 'set local row_security = off';

  select account_id
    into result
    from public.account_users
   where user_uid = auth.uid()
     and coalesce(disabled, false) = false
   order by created_at desc
   limit 1;

  return result;
end;
$$;

revoke all on function public.my_account_id() from public;
grant execute on function public.my_account_id() to authenticated;

create or replace function public.my_accounts()
returns setof uuid
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  execute 'set local row_security = off';

  return query
  select account_id
    from public.account_users
   where user_uid = auth.uid()
     and coalesce(disabled, false) = false
   order by created_at desc;
end;
$$;

revoke all on function public.my_accounts() from public;
grant execute on function public.my_accounts() to authenticated;

create or replace function public.my_profile()
returns table (
  user_uid   uuid,
  email      text,
  account_id uuid,
  role       text,
  disabled   boolean
)
language plpgsql
security definer
stable
set search_path = public, auth
as $$
begin
  execute 'set local row_security = off';

  return query
  with membership as (
    select
      au.account_id,
      au.role::text,
      coalesce(au.disabled, false) as disabled
    from public.account_users au
    where au.user_uid = auth.uid()
    order by au.created_at desc
    limit 1
  )
  select
    u.id as user_uid,
    u.email,
    membership.account_id,
    coalesce(membership.role, 'employee') as role,
    coalesce(membership.disabled, false) as disabled
  from auth.users u
  left join membership on true
  where u.id = auth.uid()
  limit 1;
end;
$$;

revoke all on function public.my_profile() from public;
grant execute on function public.my_profile() to authenticated;

create or replace function public.list_employees_with_email(p_account uuid)
returns table(
  user_uid uuid,
  email text,
  role text,
  disabled boolean,
  created_at timestamptz,
  employee_id uuid,
  doctor_id uuid
) as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'admin@elmam.com';
  can_manage boolean;
begin
  execute 'set local row_security = off';

  select exists (
    select 1
    from public.account_users
    where account_id = p_account
      and user_uid = caller_uid
      and role in ('owner','admin')
      and coalesce(disabled,false) = false
  ) into can_manage;

  if not (can_manage or caller_email = lower(super_admin_email)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    au.user_uid,
    coalesce(u.email, au.email),
    au.role,
    coalesce(au.disabled,false) as disabled,
    au.created_at,
    e.id as employee_id,
    d.id as doctor_id
  from public.account_users au
  left join auth.users u on u.id = au.user_uid
  left join public.employees e on e.account_id = au.account_id and e.user_uid = au.user_uid
  left join public.doctors d on d.account_id = au.account_id and d.user_uid = au.user_uid
  where au.account_id = p_account
  order by au.created_at desc;
end;
$$ language plpgsql
security definer
set search_path = public, auth;

revoke all on function public.list_employees_with_email(uuid) from public;
grant execute on function public.list_employees_with_email(uuid) to authenticated;
