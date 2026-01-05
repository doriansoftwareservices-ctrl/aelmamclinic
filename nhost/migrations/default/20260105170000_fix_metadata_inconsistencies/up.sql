BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Ensure core chat tables exist (no-op if already created).
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
  PRIMARY KEY (conversation_id, user_uid)
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
  local_id bigint
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
  local_id bigint
);

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
  PRIMARY KEY (message_id, user_uid, emoji)
);

CREATE TABLE IF NOT EXISTS public.chat_delivery_receipts (
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  delivered_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_uid)
);

-- Repair missing columns on existing tables (older schema variants).
DO $$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_conversations' AND column_name='created_by'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_conversations ADD COLUMN created_by uuid';
    END IF;
  END IF;

  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_attachments' AND column_name='message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_attachments ADD COLUMN message_id uuid';
    END IF;
  END IF;

  IF to_regclass('public.chat_reactions') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_reactions' AND column_name='message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_reactions ADD COLUMN message_id uuid';
    END IF;
  END IF;

  IF to_regclass('public.chat_delivery_receipts') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_delivery_receipts' AND column_name='message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_delivery_receipts ADD COLUMN message_id uuid';
    END IF;
  END IF;
END $$;

-- Align chat_group_invitations column names with metadata (inviter_uid/invitee_uid).
DO $$
BEGIN
  IF to_regclass('public.chat_group_invitations') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_group_invitations' AND column_name='inviter'
    ) AND NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_group_invitations' AND column_name='inviter_uid'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_group_invitations RENAME COLUMN inviter TO inviter_uid';
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_group_invitations' AND column_name='invitee_user'
    ) AND NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='chat_group_invitations' AND column_name='invitee_uid'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_group_invitations RENAME COLUMN invitee_user TO invitee_uid';
    END IF;
  END IF;
END $$;

-- Remove overloaded my_account_id_rpc functions and recreate the tracked signature.
DROP FUNCTION IF EXISTS public.my_account_id_rpc();
DROP FUNCTION IF EXISTS public.my_account_id_rpc(json);

CREATE OR REPLACE FUNCTION public.my_account_id_rpc(hasura_session json)
RETURNS TABLE(account_id uuid)
LANGUAGE sql
STABLE
AS $$
  SELECT public.my_account_id() AS account_id;
$$;
REVOKE ALL ON FUNCTION public.my_account_id_rpc(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id_rpc(json) TO PUBLIC;

-- Recreate admin dashboard RPCs to ensure composite return types.
DROP FUNCTION IF EXISTS public.admin_dashboard_pending_subscription_requests(json);
DROP FUNCTION IF EXISTS public.admin_dashboard_active_subscriptions(json);
DROP FUNCTION IF EXISTS public.admin_dashboard_payments(json, timestamptz);
DROP FUNCTION IF EXISTS public.admin_dashboard_revenue_monthly(json, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_audit_tail(json, uuid, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_member_counts(json, boolean);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_members(json, uuid, boolean);

CREATE OR REPLACE FUNCTION public.admin_dashboard_pending_subscription_requests(hasura_session json)
RETURNS TABLE(
  request_id uuid,
  created_at timestamptz,
  age_hours numeric,
  status text,
  account_id uuid,
  account_name text,
  requester_uid uuid,
  requester_email text,
  plan_code text,
  plan_name text,
  amount_usd numeric,
  payment_method text,
  proof_url text,
  note text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.created_at,
    round(extract(epoch FROM (now() - r.created_at))/3600.0, 2)::numeric,
    r.status,
    r.account_id,
    a.name,
    r.user_uid,
    coalesce(au.email, ''),
    r.plan_code,
    sp.name,
    coalesce(r.amount, sp.price_usd),
    pm.name,
    r.proof_url,
    r.note
  FROM public.subscription_requests r
  JOIN public.accounts a ON a.id = r.account_id
  LEFT JOIN public.subscription_plans sp ON sp.code = r.plan_code
  LEFT JOIN public.payment_methods pm ON pm.id = r.payment_method_id
  LEFT JOIN public.account_users au ON au.account_id = r.account_id AND au.user_uid = r.user_uid
  WHERE r.status = 'pending'
  ORDER BY r.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_pending_subscription_requests(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_pending_subscription_requests(json) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_active_subscriptions(hasura_session json)
RETURNS TABLE(
  account_id uuid,
  account_name text,
  plan_code text,
  plan_name text,
  status text,
  start_at timestamptz,
  end_at timestamptz,
  grace_days integer,
  effective_end_at timestamptz,
  remaining_days_including_grace numeric,
  approved_at timestamptz,
  approved_by uuid,
  approved_by_email text,
  request_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (s.account_id)
    s.account_id,
    a.name,
    s.plan_code,
    sp.name,
    s.status,
    s.start_at,
    s.end_at,
    sp.grace_days,
    CASE WHEN s.end_at IS NULL THEN NULL
         ELSE (s.end_at + (sp.grace_days::text || ' days')::interval)
    END AS effective_end_at,
    CASE WHEN s.end_at IS NULL THEN NULL
         ELSE round(extract(epoch FROM ((s.end_at + (sp.grace_days::text || ' days')::interval) - now()))/86400.0, 2)::numeric
    END AS remaining_days,
    s.approved_at,
    s.approved_by,
    sa.email,
    s.request_id
  FROM public.account_subscriptions s
  JOIN public.accounts a ON a.id = s.account_id
  LEFT JOIN public.subscription_plans sp ON sp.code = s.plan_code
  LEFT JOIN public.super_admins sa ON sa.user_uid = s.approved_by
  WHERE s.status = 'active'
  ORDER BY s.account_id, s.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_active_subscriptions(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_active_subscriptions(json) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_payments(
  hasura_session json,
  p_from timestamptz DEFAULT (now() - interval '90 days')
)
RETURNS TABLE(
  payment_id uuid,
  received_at timestamptz,
  account_id uuid,
  account_name text,
  plan_code text,
  plan_name text,
  amount_usd numeric,
  payment_method text,
  request_id uuid,
  created_by uuid,
  created_by_email text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.received_at,
    p.account_id,
    a.name,
    p.plan_code,
    sp.name,
    p.amount,
    pm.name,
    p.request_id,
    p.created_by,
    coalesce(au.email, sa.email, '')
  FROM public.subscription_payments p
  JOIN public.accounts a ON a.id = p.account_id
  LEFT JOIN public.subscription_plans sp ON sp.code = p.plan_code
  LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
  LEFT JOIN public.account_users au ON au.account_id = p.account_id AND au.user_uid = p.created_by
  LEFT JOIN public.super_admins sa ON sa.user_uid = p.created_by
  WHERE p.received_at >= p_from
  ORDER BY p.received_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_payments(json, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_payments(json, timestamptz) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_revenue_monthly(
  hasura_session json,
  p_months integer DEFAULT 12
)
RETURNS TABLE(
  month timestamptz,
  payments_count bigint,
  total_amount_usd numeric,
  avg_payment_usd numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    date_trunc('month', received_at) AS month,
    count(*) AS payments_count,
    round(sum(amount)::numeric, 2) AS total_amount_usd,
    round(avg(amount)::numeric, 2) AS avg_payment_usd
  FROM public.subscription_payments
  WHERE received_at >= date_trunc('month', now()) - (p_months::text || ' months')::interval
  GROUP BY 1
  ORDER BY 1 DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_revenue_monthly(json, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_revenue_monthly(json, integer) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_audit_tail(
  hasura_session json,
  p_account uuid DEFAULT NULL,
  p_limit integer DEFAULT 200
)
RETURNS TABLE(
  created_at timestamptz,
  account_id uuid,
  actor_uid uuid,
  actor_email text,
  table_name text,
  op text,
  row_pk text,
  diff jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    al.created_at,
    al.account_id,
    al.actor_uid,
    al.actor_email,
    al.table_name,
    al.op,
    al.row_pk,
    al.diff
  FROM public.audit_logs al
  WHERE (p_account IS NULL OR al.account_id = p_account)
    AND al.table_name IN ('subscription_requests','account_subscriptions','subscription_payments','account_feature_permissions')
  ORDER BY al.created_at DESC
  LIMIT greatest(1, least(p_limit, 2000));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_audit_tail(json, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_audit_tail(json, uuid, integer) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_account_member_counts(
  hasura_session json,
  p_only_active boolean DEFAULT true
)
RETURNS TABLE(
  account_id uuid,
  account_name text,
  owners_count bigint,
  admins_count bigint,
  employees_count bigint,
  total_members bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    au.account_id,
    a.name AS account_name,
    sum((lower(au.role) = 'owner')::int) AS owners_count,
    sum((lower(au.role) = 'admin')::int) AS admins_count,
    sum((lower(au.role) = 'employee')::int) AS employees_count,
    count(*) AS total_members
  FROM public.account_users au
  JOIN public.accounts a ON a.id = au.account_id
  WHERE (p_only_active IS DISTINCT FROM true)
     OR coalesce(au.disabled, false) = false
  GROUP BY au.account_id, a.name
  ORDER BY total_members DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_account_members(
  hasura_session json,
  p_account uuid DEFAULT NULL,
  p_only_active boolean DEFAULT true
)
RETURNS TABLE(
  account_id uuid,
  account_name text,
  user_uid uuid,
  email text,
  role text,
  disabled boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    au.account_id,
    a.name AS account_name,
    au.user_uid,
    au.email,
    au.role,
    au.disabled,
    au.created_at
  FROM public.account_users au
  JOIN public.accounts a ON a.id = au.account_id
  WHERE (p_account IS NULL OR au.account_id = p_account)
    AND ((p_only_active IS DISTINCT FROM true)
      OR coalesce(au.disabled, false) = false)
  ORDER BY a.name, au.role, au.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) TO PUBLIC;

COMMIT;
