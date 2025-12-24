CREATE TABLE IF NOT EXISTS public.super_admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  account_id uuid,
  device_id text,
  local_id bigint,
  email text UNIQUE,
  user_uid uuid UNIQUE
);
