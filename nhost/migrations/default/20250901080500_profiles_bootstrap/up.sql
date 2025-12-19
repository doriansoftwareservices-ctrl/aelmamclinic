-- 20250901080500_profiles_bootstrap.sql
-- Early bootstrap for public.profiles so that RPCs defined in 20250901090100 can reference the table.
-- Full indexes/policies remain in 20250923000000_profiles_table.sql.

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  role text NOT NULL DEFAULT 'employee',
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS profiles_account_idx ON public.profiles(account_id);
