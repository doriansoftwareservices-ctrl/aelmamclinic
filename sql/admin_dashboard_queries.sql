-- ============================================================
-- AelmamClinic — Superadmin Dashboard Queries (SQL)
-- Intended for: Hasura Console (admin) / psql
-- Tables used:
--   public.subscription_requests
--   public.account_subscriptions
--   public.subscription_payments
--   public.subscription_plans
--   public.payment_methods
--   public.accounts
--   public.account_users
--   public.super_admins
--   public.audit_logs
--   public.account_feature_permissions
-- ============================================================

/* ------------------------------------------------------------
Q1) Pending subscription requests (queue)
------------------------------------------------------------ */
SELECT
  r.id              AS request_id,
  r.created_at,
  round(extract(epoch FROM (now() - r.created_at))/3600.0, 2) AS age_hours,
  r.status,
  r.account_id,
  a.name            AS account_name,
  r.user_uid        AS requester_uid,
  coalesce(au.email, '') AS requester_email,
  r.plan_code,
  sp.name           AS plan_name,
  coalesce(r.amount, sp.price_usd) AS amount_usd,
  pm.name           AS payment_method,
  r.proof_url,
  r.note
FROM public.subscription_requests r
JOIN public.accounts a ON a.id = r.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = r.plan_code
LEFT JOIN public.payment_methods pm ON pm.id = r.payment_method_id
LEFT JOIN public.account_users au ON au.account_id = r.account_id AND au.user_uid = r.user_uid
WHERE r.status = 'pending'
ORDER BY r.created_at DESC;


/* ------------------------------------------------------------
Q2) Pending queue stats (by plan, last 30 days)
------------------------------------------------------------ */
SELECT
  r.plan_code,
  count(*) AS pending_count,
  round(avg(extract(epoch FROM (now() - r.created_at))/3600.0), 2) AS avg_age_hours,
  max(r.created_at) AS newest_request_at,
  min(r.created_at) AS oldest_request_at
FROM public.subscription_requests r
WHERE r.status = 'pending'
  AND r.created_at >= now() - interval '30 days'
GROUP BY r.plan_code
ORDER BY pending_count DESC;


/* ------------------------------------------------------------
Q3) Active subscription per account (latest active row)
------------------------------------------------------------ */
SELECT DISTINCT ON (s.account_id)
  s.account_id,
  a.name AS account_name,
  s.plan_code,
  sp.name AS plan_name,
  s.status,
  s.start_at,
  s.end_at,
  sp.grace_days,
  CASE
    WHEN s.end_at IS NULL THEN NULL
    ELSE (s.end_at + (sp.grace_days::text || ' days')::interval)
  END AS effective_end_at,
  CASE
    WHEN s.end_at IS NULL THEN NULL
    ELSE round(extract(epoch FROM ((s.end_at + (sp.grace_days::text || ' days')::interval) - now()))/86400.0, 2)
  END AS remaining_days_including_grace,
  s.approved_at,
  s.approved_by,
  sa.email AS approved_by_email,
  s.request_id
FROM public.account_subscriptions s
JOIN public.accounts a ON a.id = s.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = s.plan_code
LEFT JOIN public.super_admins sa ON sa.user_uid = s.approved_by
WHERE s.status = 'active'
ORDER BY s.account_id, s.created_at DESC;


/* ------------------------------------------------------------
Q4) Accounts expiring soon (within 14 days, including grace)
------------------------------------------------------------ */
SELECT
  s.account_id,
  a.name AS account_name,
  s.plan_code,
  sp.name AS plan_name,
  s.end_at,
  sp.grace_days,
  (s.end_at + (sp.grace_days::text || ' days')::interval) AS effective_end_at,
  round(extract(epoch FROM ((s.end_at + (sp.grace_days::text || ' days')::interval) - now()))/86400.0, 2) AS remaining_days
FROM public.account_subscriptions s
JOIN public.accounts a ON a.id = s.account_id
JOIN public.subscription_plans sp ON sp.code = s.plan_code
WHERE s.status = 'active'
  AND s.end_at IS NOT NULL
  AND (s.end_at + (sp.grace_days::text || ' days')::interval) <= now() + interval '14 days'
ORDER BY remaining_days ASC;


/* ------------------------------------------------------------
Q5) Payments (last 90 days)
------------------------------------------------------------ */
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
LEFT JOIN public.super_admins sa ON sa.user_uid = p.created_by
WHERE p.received_at >= now() - interval '90 days'
ORDER BY p.received_at DESC;


/* ------------------------------------------------------------
Q6) Revenue by month (last 12 months)
------------------------------------------------------------ */
SELECT
  date_trunc('month', received_at) AS month,
  count(*) AS payments_count,
  round(sum(amount)::numeric, 2) AS total_amount_usd,
  round(avg(amount)::numeric, 2) AS avg_payment_usd
FROM public.subscription_payments
WHERE received_at >= date_trunc('month', now()) - interval '12 months'
GROUP BY 1
ORDER BY 1 DESC;


/* ------------------------------------------------------------
Q7) Plan distribution (paid vs free) — computed from latest active subscription
------------------------------------------------------------ */
WITH latest_active AS (
  SELECT DISTINCT ON (s.account_id)
    s.account_id,
    s.plan_code,
    s.end_at,
    s.created_at
  FROM public.account_subscriptions s
  WHERE s.status = 'active'
  ORDER BY s.account_id, s.created_at DESC
)
SELECT
  coalesce(plan_code, 'free') AS plan_code,
  count(*) AS accounts_count
FROM latest_active
GROUP BY 1
ORDER BY accounts_count DESC;


/* ------------------------------------------------------------
Q8) Inconsistency checks
  (a) Accounts with multiple active subscriptions
------------------------------------------------------------ */
SELECT
  account_id,
  count(*) AS active_count,
  min(created_at) AS first_active_at,
  max(created_at) AS last_active_at
FROM public.account_subscriptions
WHERE status = 'active'
GROUP BY account_id
HAVING count(*) > 1
ORDER BY active_count DESC;


/* ------------------------------------------------------------
Q8b) Approved requests without an active subscription referencing request_id
------------------------------------------------------------ */
SELECT
  r.id AS request_id,
  r.account_id,
  a.name AS account_name,
  r.plan_code,
  r.updated_at AS request_updated_at
FROM public.subscription_requests r
JOIN public.accounts a ON a.id = r.account_id
LEFT JOIN public.account_subscriptions s
  ON s.request_id = r.id AND s.status = 'active'
WHERE r.status = 'approved'
  AND s.id IS NULL
ORDER BY r.updated_at DESC;


/* ------------------------------------------------------------
Q8c) Active subscriptions but missing feature-permission rows (should be at least members count)
------------------------------------------------------------ */
WITH members AS (
  SELECT account_id, count(*) AS member_count
  FROM public.account_users
  WHERE disabled = false
  GROUP BY account_id
),
perm AS (
  SELECT account_id, count(*) AS perm_count
  FROM public.account_feature_permissions
  GROUP BY account_id
)
SELECT
  m.account_id,
  a.name AS account_name,
  m.member_count,
  coalesce(p.perm_count, 0) AS perm_count
FROM members m
JOIN public.accounts a ON a.id = m.account_id
LEFT JOIN perm p ON p.account_id = m.account_id
WHERE coalesce(p.perm_count, 0) < m.member_count
ORDER BY (m.member_count - coalesce(p.perm_count,0)) DESC;


/* ------------------------------------------------------------
Q9) Audit trail (last 200 events; filter billing domain)
------------------------------------------------------------ */
SELECT
  created_at,
  account_id,
  actor_uid,
  actor_email,
  table_name,
  op,
  row_pk,
  diff
FROM public.audit_logs
WHERE table_name IN ('subscription_requests','account_subscriptions','subscription_payments','account_feature_permissions')
ORDER BY created_at DESC
LIMIT 200;
