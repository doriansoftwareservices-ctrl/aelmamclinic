-- 20250913010000_restore_core_domain.sql
-- Restores the business/chat schema expected by the Flutter application.
-- All definitions mirror the archived schema that lib/ relies on, while using
-- IF NOT EXISTS guards so we can apply safely onto existing environments.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Super admins registry -------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.super_admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  account_id uuid,
  device_id text,
  local_id bigint,
  email text UNIQUE,
  user_uid uuid UNIQUE
);

-- Core business tables --------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  device_id text NOT NULL DEFAULT '',
  name text,
  age smallint,
  diagnosis text,
  phone_number text,
  register_date date,
  paid_amount numeric NOT NULL DEFAULT 0,
  remaining numeric NOT NULL DEFAULT 0,
  health_status text,
  notes text,
  preferences text,
  doctor_id uuid,
  doctor_name text,
  doctor_specialization text,
  service_type text,
  service_id uuid,
  service_name text,
  service_cost numeric,
  doctor_share numeric NOT NULL DEFAULT 0,
  doctor_input numeric NOT NULL DEFAULT 0,
  tower_share numeric NOT NULL DEFAULT 0,
  department_share numeric NOT NULL DEFAULT 0,
  doctor_review_pending boolean NOT NULL DEFAULT false,
  doctor_reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  is_deleted boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS public.returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  date timestamptz,
  patient_name text,
  phone_number text,
  diagnosis text,
  remaining double precision,
  age integer,
  doctor text,
  notes text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.consumptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id text,
  item_id text,
  quantity integer,
  date timestamptz,
  amount double precision,
  note text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.drugs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.prescriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id uuid REFERENCES public.patients(id) ON DELETE CASCADE,
  doctor_id uuid,
  record_date timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.prescription_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  prescription_id uuid REFERENCES public.prescriptions(id) ON DELETE CASCADE,
  drug_id uuid REFERENCES public.drugs(id) ON DELETE SET NULL,
  days integer,
  times_per_day integer,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.complaints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  title text,
  description text,
  status text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.appointments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id uuid REFERENCES public.patients(id) ON DELETE CASCADE,
  doctor_id uuid,
  appointment_time timestamptz,
  status text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.doctors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid,
  user_uid uuid,
  name text,
  specialization text,
  phone_number text,
  start_time timestamptz,
  end_time timestamptz,
  print_counter integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.consumption_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  type text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.medical_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text,
  cost numeric,
  service_type text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.service_doctor_share (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  service_id uuid REFERENCES public.medical_services(id) ON DELETE CASCADE,
  doctor_id uuid REFERENCES public.doctors(id) ON DELETE CASCADE,
  share_percentage numeric,
  tower_share_percentage numeric,
  is_hidden boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text,
  identity_number text,
  phone_number text,
  job_title text,
  address text,
  marital_status text,
  basic_salary numeric,
  final_salary numeric,
  is_doctor boolean NOT NULL DEFAULT false,
  user_uid uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.employees_loans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE,
  loan_date_time timestamptz,
  final_salary numeric,
  ratio_sum numeric,
  loan_amount numeric,
  leftover numeric,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.employees_salaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE,
  year integer,
  month integer,
  final_salary numeric,
  ratio_sum numeric,
  total_loans numeric,
  net_pay numeric,
  is_paid boolean NOT NULL DEFAULT false,
  payment_date timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.employees_discounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE,
  discount_date_time timestamptz,
  amount numeric,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.item_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS item_types_unique_name
  ON public.item_types (account_id, lower(name));

CREATE TABLE IF NOT EXISTS public.items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  type_id uuid REFERENCES public.item_types(id) ON DELETE SET NULL,
  name text,
  price numeric,
  stock numeric,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS items_unique_type_name
  ON public.items (account_id, type_id, lower(name));

CREATE TABLE IF NOT EXISTS public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  date timestamptz,
  item_id uuid REFERENCES public.items(id) ON DELETE SET NULL,
  quantity integer,
  total double precision,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.alert_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  item_id uuid REFERENCES public.items(id) ON DELETE SET NULL,
  item_uuid uuid REFERENCES public.items(id) ON DELETE SET NULL,
  threshold double precision,
  notify_time timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  is_enabled boolean NOT NULL DEFAULT true,
  last_triggered timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.financial_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  transaction_type text,
  operation text,
  amount double precision,
  employee_id text,
  description text,
  modification_details text,
  "timestamp" timestamptz,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.patient_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id uuid REFERENCES public.patients(id) ON DELETE CASCADE,
  service_id uuid REFERENCES public.medical_services(id) ON DELETE SET NULL,
  service_name text,
  service_cost numeric,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT ''
);

-- Chat tables -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  title text,
  is_group boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_msg_at timestamptz,
  last_msg_snippet text,
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS public.chat_participants (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  email text,
  nickname text,
  role text,
  joined_at timestamptz,
  muted boolean NOT NULL DEFAULT false,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  sender_uid uuid NOT NULL,
  sender_email text,
  kind text NOT NULL DEFAULT 'text',
  body text,
  text text,
  attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  mentions jsonb NOT NULL DEFAULT '[]'::jsonb,
  reply_to_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  reply_to_id text,
  reply_to_snippet text,
  patient_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  edited boolean NOT NULL DEFAULT false,
  edited_at timestamptz,
  deleted boolean NOT NULL DEFAULT false,
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id text,
  local_id bigint,
  FOREIGN KEY (account_id, sender_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_messages_device_local
  ON public.chat_messages (account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.chat_reads (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  last_read_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  last_read_at timestamptz,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

CREATE TABLE IF NOT EXISTS public.chat_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  bucket text NOT NULL DEFAULT 'chat-attachments',
  path text NOT NULL,
  mime_type text,
  size_bytes integer,
  width integer,
  height integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id text,
  local_id bigint,
  FOREIGN KEY (message_id)
    REFERENCES public.chat_messages(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_attachments_device_local
  ON public.chat_attachments (account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.chat_reactions (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  emoji text NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id text,
  local_id bigint,
  PRIMARY KEY (message_id, user_uid, emoji),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_reactions_device_local
  ON public.chat_reactions (account_id, device_id, local_id, emoji)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

-- Supporting indexes on frequently queried columns ---------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_account_lower_name
  ON public.drugs (account_id, lower(name));

CREATE UNIQUE INDEX IF NOT EXISTS service_doctor_share_unique
  ON public.service_doctor_share (account_id, service_id, doctor_id);

-- Triplet indexes & account indexes for sync tables --------------------------
DO $$
DECLARE
  tbl text;
BEGIN
  FOR tbl IN SELECT unnest(ARRAY[
    'patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services','account_users','super_admins'
  ]) LOOP
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I_account_device_local_idx ON public.%I (account_id, device_id, local_id)', tbl, tbl);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I_account_idx ON public.%I (account_id)', tbl, tbl);
  END LOOP;
END $$;

-- Updated_at maintenance triggers -------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  tbl text;
  managed_tables constant text[] := ARRAY[
    'account_users','account_feature_permissions','patients','returns','consumptions','drugs',
    'prescriptions','prescription_items','complaints','appointments','doctors','consumption_types',
    'medical_services','service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings','financial_logs',
    'patient_services'
  ];
BEGIN
  FOR tbl IN SELECT unnest(managed_tables) LOOP
    IF to_regclass('public.'||tbl) IS NULL THEN CONTINUE; END IF;EXECUTE format('DROP TRIGGER IF EXISTS %I_set_updated_at ON public.%I', tbl, tbl);
    EXECUTE format('CREATE TRIGGER %I_set_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at()', tbl, tbl);
  END LOOP;
END $$;

