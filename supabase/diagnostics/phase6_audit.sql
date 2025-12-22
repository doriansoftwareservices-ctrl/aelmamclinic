-- Phase 6 data audit (run in Supabase SQL editor as service_role).
-- Focus: super_admins/user_uid linkage, account_users integrity, profiles sync.

-- 1) Super admins missing user_uid (invalid for unified auth)
select *
from public.super_admins
where user_uid is null;

-- 2) Super admins pointing to missing auth.users
select sa.*
from public.super_admins sa
left join auth.users u on u.id = sa.user_uid
where sa.user_uid is not null and u.id is null;

-- 3) Orphan account_users (no matching auth.users)
select au.*
from public.account_users au
left join auth.users u on u.id = au.user_uid
where u.id is null;

-- 4) Orphan account_users (no matching accounts)
select au.*
from public.account_users au
left join public.accounts a on a.id = au.account_id
where a.id is null;

-- 5) Accounts without any owner
select a.id, a.name
from public.accounts a
left join public.account_users au
  on au.account_id = a.id
  and lower(coalesce(au.role, '')) = 'owner'
  and coalesce(au.disabled, false) = false
where au.account_id is null;

-- 6) account_users missing profiles (if profiles table exists)
select au.account_id, au.user_uid, au.role
from public.account_users au
left join public.profiles p on p.id = au.user_uid
where p.id is null;

-- 7) profiles without account_users membership
select p.id, p.account_id, p.role
from public.profiles p
left join public.account_users au on au.user_uid = p.id
where au.user_uid is null;

-- 8) Role mismatches between profiles and account_users (latest membership)
with latest_membership as (
  select distinct on (au.user_uid) au.user_uid, au.account_id, au.role, au.disabled
  from public.account_users au
  order by au.user_uid, au.created_at desc
)
select lm.user_uid, lm.account_id, lm.role as account_role, p.role as profile_role
from latest_membership lm
join public.profiles p on p.id = lm.user_uid
where lower(coalesce(lm.role, '')) <> lower(coalesce(p.role, ''));

-- 9) Disabled users still marked as active in profiles
select au.user_uid, au.account_id, au.disabled, p.role as profile_role
from public.account_users au
join public.profiles p on p.id = au.user_uid
where coalesce(au.disabled, false) = true
  and lower(coalesce(p.role, '')) not in ('disabled', 'removed');
