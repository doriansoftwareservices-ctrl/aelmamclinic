--//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\supabase\migrations\20250901090200_rpc_list_employees_with_email.sql
-- تُرجع موظفي الحساب مع البريد الإلكتروني (تعتمد على auth.users + account_users)
-- سماحية الاستدعاء: owner/admin على نفس الحساب، أو السوبر أدمن بالبريد المحدد.

drop function if exists public.list_employees_with_email(uuid);
create or replace function public.list_employees_with_email(p_account uuid)
returns table(
  user_uid uuid,
  email text,
  role text,
  disabled boolean,
  created_at timestamptz
) as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'admin@elmam.com';
  can_manage boolean;
begin
  -- تحقق الصلاحيات: (owner/admin) على الحساب أو سوبر أدمن بالبريد
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
    u.email,
    au.role,
    coalesce(au.disabled,false) as disabled,
    au.created_at
  from public.account_users au
  left join auth.users u on u.id = au.user_uid
  where au.account_id = p_account
  order by au.created_at desc;
end;
$$ language plpgsql
security definer
set search_path = public, auth;
revoke all on function public.list_employees_with_email(uuid) from public;
grant execute on function public.list_employees_with_email(uuid) TO public;
