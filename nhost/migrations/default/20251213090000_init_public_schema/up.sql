-- Bootstrap of core public schema tables migrated from Supabase.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS public.accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  frozen boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.account_users (
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'employee',
  disabled boolean NOT NULL DEFAULT false,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  local_id bigint,
  PRIMARY KEY (account_id, user_uid)
);

CREATE INDEX IF NOT EXISTS account_users_account_idx
  ON public.account_users(account_id);
CREATE INDEX IF NOT EXISTS account_users_user_idx
  ON public.account_users(user_uid);
CREATE INDEX IF NOT EXISTS account_users_role_idx
  ON public.account_users(role);
