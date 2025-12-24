-- Fix admin_create_owner_full ambiguity and provide 2-arg bootstrap wrapper.

create or replace function public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  owner_uid uuid;
  v_account_id uuid;
begin
  if coalesce(trim(p_clinic_name), '') = '' or coalesce(trim(p_owner_email), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'clinic_name and owner_email are required');
  end if;

  if fn_is_super_admin() is distinct from true then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select id
    into owner_uid
  from auth.users
  where lower(email) = lower(p_owner_email)
  order by created_at desc
  limit 1;

  if owner_uid is null then
    return jsonb_build_object('ok', false, 'error', 'owner user not found');
  end if;

  insert into public.accounts(name, frozen)
  values (p_clinic_name, false)
  returning id into v_account_id;

  perform public.admin_attach_employee(v_account_id, owner_uid, 'owner');

  update public.account_users au
     set email = lower(p_owner_email)
   where au.account_id = v_account_id
     and au.user_uid = owner_uid;

  return jsonb_build_object('ok', true, 'account_id', v_account_id::text, 'owner_uid', owner_uid::text);
end;
$$;

revoke all on function public.admin_create_owner_full(text, text, text) from public;
grant execute on function public.admin_create_owner_full(text, text, text) TO public;
grant execute on function public.admin_create_owner_full(text, text, text) TO public;

create or replace function public.admin_bootstrap_clinic_for_email(
  clinic_name text,
  owner_email text
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.admin_bootstrap_clinic_for_email(clinic_name, owner_email, 'owner');
end;
$$;

revoke all on function public.admin_bootstrap_clinic_for_email(text, text) from public;
grant execute on function public.admin_bootstrap_clinic_for_email(text, text) TO public;
grant execute on function public.admin_bootstrap_clinic_for_email(text, text) TO public;
