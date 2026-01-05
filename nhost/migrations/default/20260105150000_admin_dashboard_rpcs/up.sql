BEGIN;

-- ============================================================
-- Optional: Superadmin-only RPCs for dashboard consumption (GraphQL)
-- Each function is guarded by fn_is_super_admin().
-- ============================================================

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

COMMIT;
