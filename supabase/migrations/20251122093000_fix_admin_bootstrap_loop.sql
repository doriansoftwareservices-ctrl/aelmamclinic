-- 20251122093000_fix_admin_bootstrap_loop.sql
-- Fixes the accidental recursion on admin_bootstrap_clinic_for_email by
-- restoring the original 3-arg implementation plus the thin 2-arg wrapper.

create or replace function public.admin_bootstrap_clinic_for_email(
  clinic_name text,
  owner_email text,
  owner_role text default 'owner'
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
  normalized_email text := lower(coalesce(trim(owner_email), ''));
  normalized_role text := coalesce(nullif(trim(owner_role), ''), 'owner');
  owner_uid uuid;
  acc_id uuid;
begin
  if coalesce(trim(clinic_name), '') = '' then
    raise exception 'clinic_name is required';
  end if;

  if normalized_email = '' then
    raise exception 'owner_email is required';
  end if;

  if not (fn_is_super_admin() = true or caller_email = super_admin_email) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select id
    into owner_uid
  from auth.users
  where lower(email) = normalized_email
  order by created_at desc
  limit 1;

  if owner_uid is null then
    raise exception 'owner with email % not found in auth.users', normalized_email;
  end if;

  insert into public.accounts(name, frozen)
  values (clinic_name, false)
  returning id into acc_id;

  perform public.admin_attach_employee(acc_id, owner_uid, normalized_role);

  update public.account_users
     set email = normalized_email,
         role = normalized_role,
         updated_at = now()
   where account_id = acc_id
     and user_uid = owner_uid;

  return acc_id;
end;
$$;

revoke all on function public.admin_bootstrap_clinic_for_email(text, text, text) from public;
grant execute on function public.admin_bootstrap_clinic_for_email(text, text, text) to authenticated;

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
grant execute on function public.admin_bootstrap_clinic_for_email(text, text) to authenticated;
