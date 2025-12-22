-- Phase 6 data fixes (run in Supabase SQL editor as service_role).
-- Use after reviewing results from supabase/diagnostics/phase6_audit.sql
-- IMPORTANT: Replace placeholders before executing.

-- 1) Fix super_admins missing user_uid
-- Update user_uid using auth.users lookup by email.
-- Example:
-- update public.super_admins sa
-- set user_uid = u.id
-- from auth.users u
-- where sa.user_uid is null
--   and lower(sa.email) = lower(u.email);

-- 2) Remove super_admins rows pointing to missing auth.users (after verification).
-- Example:
-- delete from public.super_admins sa
-- where sa.user_uid is not null
--   and not exists (select 1 from auth.users u where u.id = sa.user_uid);

-- 3) Remove account_users rows with missing auth.users (after verification).
-- Example:
-- delete from public.account_users au
-- where not exists (select 1 from auth.users u where u.id = au.user_uid);

-- 4) Remove account_users rows with missing accounts (after verification).
-- Example:
-- delete from public.account_users au
-- where not exists (select 1 from public.accounts a where a.id = au.account_id);

-- 5) Assign owner role to a specific user for accounts that lack an owner.
-- Replace :account_id and :user_uid with real values.
-- Example:
-- insert into public.account_users(account_id, user_uid, role, disabled)
-- values (:account_id, :user_uid, 'owner', false)
-- on conflict (account_id, user_uid) do update
--   set role = 'owner', disabled = false, updated_at = now();

-- 6) Create missing profile rows from account_users (latest membership).
-- Example:
-- insert into public.profiles(id, account_id, role, created_at)
-- select au.user_uid, au.account_id, coalesce(au.role, 'employee'), now()
-- from public.account_users au
-- left join public.profiles p on p.id = au.user_uid
-- where p.id is null
-- on conflict (id) do nothing;

-- 7) Align profile role with latest account_users role.
-- Example:
-- with latest_membership as (
--   select distinct on (au.user_uid) au.user_uid, au.account_id, au.role, au.disabled
--   from public.account_users au
--   order by au.user_uid, au.created_at desc
-- )
-- update public.profiles p
-- set role = lm.role, account_id = lm.account_id, updated_at = now()
-- from latest_membership lm
-- where p.id = lm.user_uid
--   and lower(coalesce(p.role, '')) <> lower(coalesce(lm.role, ''));

-- 8) Mark profiles as disabled for disabled account_users.
-- Example:
-- update public.profiles p
-- set role = 'disabled', updated_at = now()
-- from public.account_users au
-- where au.user_uid = p.id
--   and coalesce(au.disabled, false) = true
--   and lower(coalesce(p.role, '')) not in ('disabled', 'removed');

-- 9) Optional: backfill account_users.email from auth.users.
-- Example:
-- update public.account_users au
-- set email = lower(u.email), updated_at = now()
-- from auth.users u
-- where au.user_uid = u.id
--   and (au.email is null or au.email = '');
