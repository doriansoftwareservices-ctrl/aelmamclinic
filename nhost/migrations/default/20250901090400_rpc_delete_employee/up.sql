--//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\supabase\migrations\20250901090400_rpc_delete_employee.sql
-- حذف ربط موظف بالحساب (لا يحذف مستخدم auth).
-- سماحية الاستدعاء: owner/admin على الحساب أو السوبر أدمن.

drop function if exists public.delete_employee(uuid, uuid);
create or replace function public.delete_employee(
  p_account uuid,
  p_user_uid uuid
)
returns void as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
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

  delete from public.account_users
   where account_id = p_account
     and user_uid = p_user_uid;

  -- اختياري: وسم البروفايل كـ "removed" بدلاً من الحذف
  update public.profiles
     set role = 'removed'
   where id = p_user_uid
     and coalesce(account_id, p_account) = p_account;
end;
$$ language plpgsql
security definer
set search_path = public, auth;
revoke all on function public.delete_employee(uuid, uuid) from public;
grant execute on function public.delete_employee(uuid, uuid) TO public;
