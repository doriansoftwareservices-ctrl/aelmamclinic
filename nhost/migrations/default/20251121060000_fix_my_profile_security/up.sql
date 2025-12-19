-- 20251121060000_fix_my_profile_security.sql
-- Restores security definer semantics for my_profile() so authenticated users
-- can read their auth.users row without direct table grants.

create or replace function public.my_profile()
returns table (
  user_uid   uuid,
  email      text,
  account_id uuid,
  role       text,
  disabled   boolean
)
language sql
security definer
stable
set search_path = public, auth
as $$
  with membership as (
    select
      au.account_id,
      au.role::text,
      coalesce(au.disabled, false) as disabled
    from public.account_users au
    where au.user_uid = nullif(public.request_uid_text(), '')::uuid
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
  where u.id = nullif(public.request_uid_text(), '')::uuid
  limit 1;
$$;

revoke all on function public.my_profile() from public;
grant execute on function public.my_profile() TO public;
