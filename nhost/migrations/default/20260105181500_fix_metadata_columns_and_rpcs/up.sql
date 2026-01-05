BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Ensure expected chat columns exist (required by metadata permissions).
ALTER TABLE IF EXISTS public.chat_conversations
  ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid();

ALTER TABLE IF EXISTS public.chat_participants
  ADD COLUMN IF NOT EXISTS conversation_id uuid;

ALTER TABLE IF EXISTS public.chat_attachments
  ADD COLUMN IF NOT EXISTS message_id uuid;

ALTER TABLE IF EXISTS public.chat_reactions
  ADD COLUMN IF NOT EXISTS message_id uuid;

ALTER TABLE IF EXISTS public.chat_delivery_receipts
  ADD COLUMN IF NOT EXISTS message_id uuid;

-- Rowtype views for admin dashboard functions (required for Hasura tracking).
CREATE OR REPLACE VIEW public.v_admin_dashboard_pending_subscription_requests AS
SELECT
  r.id AS request_id,
  r.created_at,
  round(extract(epoch FROM (now() - r.created_at))/3600.0, 2)::numeric AS age_hours,
  r.status,
  r.account_id,
  a.name AS account_name,
  r.user_uid AS requester_uid,
  coalesce(au.email, '') AS requester_email,
  r.plan_code,
  sp.name AS plan_name,
  coalesce(r.amount, sp.price_usd) AS amount_usd,
  pm.name AS payment_method,
  r.proof_url,
  r.note
FROM public.subscription_requests r
JOIN public.accounts a ON a.id = r.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = r.plan_code
LEFT JOIN public.payment_methods pm ON pm.id = r.payment_method_id
LEFT JOIN public.account_users au ON au.account_id = r.account_id AND au.user_uid = r.user_uid;

CREATE OR REPLACE VIEW public.v_admin_dashboard_active_subscriptions AS
SELECT DISTINCT ON (s.account_id)
  s.account_id,
  a.name AS account_name,
  s.plan_code,
  sp.name AS plan_name,
  s.status,
  s.start_at,
  s.end_at,
  sp.grace_days,
  CASE WHEN s.end_at IS NULL THEN NULL
       ELSE (s.end_at + (sp.grace_days::text || ' days')::interval)
  END AS effective_end_at,
  CASE WHEN s.end_at IS NULL THEN NULL
       ELSE round(extract(epoch FROM ((s.end_at + (sp.grace_days::text || ' days')::interval) - now()))/86400.0, 2)::numeric
  END AS remaining_days_including_grace,
  s.approved_at,
  s.approved_by,
  sa.email AS approved_by_email,
  s.request_id
FROM public.account_subscriptions s
JOIN public.accounts a ON a.id = s.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = s.plan_code
LEFT JOIN public.super_admins sa ON sa.user_uid = s.approved_by
ORDER BY s.account_id, s.created_at DESC;

CREATE OR REPLACE VIEW public.v_admin_dashboard_payments AS
SELECT
  p.id AS payment_id,
  p.received_at,
  p.account_id,
  a.name AS account_name,
  p.plan_code,
  sp.name AS plan_name,
  p.amount AS amount_usd,
  pm.name AS payment_method,
  p.request_id,
  p.created_by,
  coalesce(au.email, sa.email, '') AS created_by_email
FROM public.subscription_payments p
JOIN public.accounts a ON a.id = p.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = p.plan_code
LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
LEFT JOIN public.account_users au ON au.account_id = p.account_id AND au.user_uid = p.created_by
LEFT JOIN public.super_admins sa ON sa.user_uid = p.created_by;

CREATE OR REPLACE VIEW public.v_admin_dashboard_revenue_monthly AS
SELECT
  date_trunc('month', received_at) AS month,
  count(*) AS payments_count,
  round(sum(amount)::numeric, 2) AS total_amount_usd,
  round(avg(amount)::numeric, 2) AS avg_payment_usd
FROM public.subscription_payments
GROUP BY 1;

CREATE OR REPLACE VIEW public.v_admin_dashboard_audit_tail AS
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
WHERE al.table_name IN (
  'subscription_requests',
  'account_subscriptions',
  'subscription_payments',
  'account_feature_permissions'
);

CREATE OR REPLACE VIEW public.v_admin_dashboard_account_member_counts AS
SELECT
  au.account_id,
  a.name AS account_name,
  sum((lower(au.role) = 'owner')::int) AS owners_count,
  sum((lower(au.role) = 'admin')::int) AS admins_count,
  sum((lower(au.role) = 'employee')::int) AS employees_count,
  count(*) AS total_members
FROM public.account_users au
JOIN public.accounts a ON a.id = au.account_id
GROUP BY au.account_id, a.name;

CREATE OR REPLACE VIEW public.v_admin_dashboard_account_members AS
SELECT
  au.account_id,
  a.name AS account_name,
  au.user_uid,
  au.email,
  au.role,
  au.disabled,
  au.created_at
FROM public.account_users au
JOIN public.accounts a ON a.id = au.account_id;

-- Recreate RPCs with view-based row types (trackable).
DROP FUNCTION IF EXISTS public.admin_dashboard_pending_subscription_requests(json);
DROP FUNCTION IF EXISTS public.admin_dashboard_active_subscriptions(json);
DROP FUNCTION IF EXISTS public.admin_dashboard_payments(json, timestamptz);
DROP FUNCTION IF EXISTS public.admin_dashboard_revenue_monthly(json, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_audit_tail(json, uuid, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_member_counts(json, boolean);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_members(json, uuid, boolean);
DROP FUNCTION IF EXISTS public.my_account_id_rpc(json);

CREATE OR REPLACE FUNCTION public.my_account_id_rpc(hasura_session json)
RETURNS SETOF public.v_my_account_id
LANGUAGE sql
STABLE
AS $$
  SELECT * FROM public.v_my_account_id;
$$;
REVOKE ALL ON FUNCTION public.my_account_id_rpc(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id_rpc(json) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_pending_subscription_requests(hasura_session json)
RETURNS SETOF public.v_admin_dashboard_pending_subscription_requests
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
  SELECT *
  FROM public.v_admin_dashboard_pending_subscription_requests
  WHERE status = 'pending'
  ORDER BY created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_pending_subscription_requests(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_pending_subscription_requests(json) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_active_subscriptions(hasura_session json)
RETURNS SETOF public.v_admin_dashboard_active_subscriptions
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
  SELECT *
  FROM public.v_admin_dashboard_active_subscriptions
  WHERE status = 'active'
  ORDER BY account_id, approved_at DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_active_subscriptions(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_active_subscriptions(json) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_payments(
  hasura_session json,
  p_from timestamptz DEFAULT (now() - interval '90 days')
)
RETURNS SETOF public.v_admin_dashboard_payments
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
  SELECT *
  FROM public.v_admin_dashboard_payments
  WHERE received_at >= p_from
  ORDER BY received_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_payments(json, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_payments(json, timestamptz) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_revenue_monthly(
  hasura_session json,
  p_months integer DEFAULT 12
)
RETURNS SETOF public.v_admin_dashboard_revenue_monthly
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
  SELECT *
  FROM public.v_admin_dashboard_revenue_monthly
  WHERE month >= date_trunc('month', now()) - (p_months::text || ' months')::interval
  ORDER BY month DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_revenue_monthly(json, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_revenue_monthly(json, integer) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_audit_tail(
  hasura_session json,
  p_account uuid DEFAULT NULL,
  p_limit integer DEFAULT 200
)
RETURNS SETOF public.v_admin_dashboard_audit_tail
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
  SELECT *
  FROM public.v_admin_dashboard_audit_tail
  WHERE (p_account IS NULL OR account_id = p_account)
  ORDER BY created_at DESC
  LIMIT greatest(1, least(p_limit, 2000));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_audit_tail(json, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_audit_tail(json, uuid, integer) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_account_member_counts(
  hasura_session json,
  p_only_active boolean DEFAULT true
)
RETURNS SETOF public.v_admin_dashboard_account_member_counts
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
  SELECT *
  FROM public.v_admin_dashboard_account_member_counts
  WHERE (p_only_active IS DISTINCT FROM true)
     OR account_id IN (
       SELECT account_id FROM public.account_users WHERE coalesce(disabled, false) = false
     )
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
RETURNS SETOF public.v_admin_dashboard_account_members
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
  SELECT *
  FROM public.v_admin_dashboard_account_members
  WHERE (p_account IS NULL OR account_id = p_account)
    AND ((p_only_active IS DISTINCT FROM true)
      OR coalesce(disabled, false) = false)
  ORDER BY account_name, role, created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) TO PUBLIC;

COMMIT;
