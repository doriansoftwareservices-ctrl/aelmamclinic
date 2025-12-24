-- 20250923000000_profiles_table.sql
-- Creates the public.profiles table required by edge/admin functions and client fallbacks.
-- Ensures RLS policies align with account permissions and super admin overrides.

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  role text NOT NULL DEFAULT 'employee',
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS profiles_account_idx ON public.profiles(account_id);
-- keep updated_at fresh
CREATE OR REPLACE FUNCTION public.tg_profiles_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS profiles_set_updated_at ON public.profiles;
CREATE TRIGGER profiles_set_updated_at
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.tg_profiles_set_updated_at();
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO PUBLIC;
-- policies: allow super admin, account managers, or the profile owner
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'profiles_select_own_or_account'
  ) THEN
    CREATE POLICY profiles_select_own_or_account
      ON public.profiles
      FOR SELECT TO PUBLIC
      USING (
        fn_is_super_admin() = true
        OR id::text = nullif(public.request_uid_text(), '')::uuid::text
        OR (
          account_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.account_users au
            WHERE au.account_id = profiles.account_id
              AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
              AND coalesce(au.disabled, false) = false
          )
        )
      );
  END IF;
END $$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'profiles_insert_account_managers'
  ) THEN
    CREATE POLICY profiles_insert_account_managers
      ON public.profiles
      FOR INSERT TO PUBLIC
      WITH CHECK (
        fn_is_super_admin() = true
        OR (
          account_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.account_users au
            WHERE au.account_id = profiles.account_id
              AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
              AND coalesce(au.disabled, false) = false
              AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
          )
        )
      );
  END IF;
END $$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'profiles_update_account_managers'
  ) THEN
    CREATE POLICY profiles_update_account_managers
      ON public.profiles
      FOR UPDATE TO PUBLIC
      USING (
        fn_is_super_admin() = true
        OR id::text = nullif(public.request_uid_text(), '')::uuid::text
        OR (
          account_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.account_users au
            WHERE au.account_id = profiles.account_id
              AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
              AND coalesce(au.disabled, false) = false
              AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
          )
        )
      )
      WITH CHECK (
        fn_is_super_admin() = true
        OR id::text = nullif(public.request_uid_text(), '')::uuid::text
        OR (
          account_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.account_users au
            WHERE au.account_id = profiles.account_id
              AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
              AND coalesce(au.disabled, false) = false
              AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
          )
        )
      );
  END IF;
END $$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'profiles_delete_account_managers'
  ) THEN
    CREATE POLICY profiles_delete_account_managers
      ON public.profiles
      FOR DELETE TO PUBLIC
      USING (
        fn_is_super_admin() = true
        OR (
          account_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.account_users au
            WHERE au.account_id = profiles.account_id
              AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
              AND coalesce(au.disabled, false) = false
              AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
          )
        )
      );
  END IF;
END $$;
