--//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\supabase\migrations\20250901090300_rpc_set_employee_disabled.sql

-- تمكين/تعطيل موظف ضمن حساب معيّن.
-- سماحية الاستدعاء: owner/admin على الحساب أو السوبر أدمن.

drop function if exists public.set_employee_disabled(uuid, uuid, boolean);
create or replace function public.set_employee_disabled(
  p_account uuid,
  p_user_uid uuid,
  p_disabled boolean
)
returns void as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
  target_role text;
begin
  select exists (
    select 1
    from public.account_users
    where account_id = p_account
      and user_uid = caller_uid
      and lower(coalesce(role,'')) in ('owner','admin','superadmin')
      and coalesce(disabled,false) = false
  ) into can_manage;

  if not (can_manage or is_super_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.account_users
     set disabled = coalesce(p_disabled, false)
   where account_id = p_account
     and user_uid = p_user_uid;

  select nullif(lower(coalesce(role, '')), '')
    into target_role
  from public.account_users
  where account_id = p_account
    and user_uid = p_user_uid
  limit 1;

  -- اختياري: عكس الحالة على profiles (لو موجود)
  update public.profiles
     set role = case
                  when p_disabled then 'disabled'
                  else coalesce(target_role, 'employee')
                end,
         account_id = coalesce(account_id, p_account)
   where id = p_user_uid;
end;
$$ language plpgsql
security definer
set search_path = public, auth;
revoke all on function public.set_employee_disabled(uuid, uuid, boolean) from public;
grant execute on function public.set_employee_disabled(uuid, uuid, boolean) to authenticated;
