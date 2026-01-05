BEGIN;

DROP FUNCTION IF EXISTS public.admin_dashboard_account_members(json, uuid, boolean);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_member_counts(json, boolean);
DROP FUNCTION IF EXISTS public.admin_dashboard_audit_tail(json, uuid, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_revenue_monthly(json, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_payments(json, timestamptz);
DROP FUNCTION IF EXISTS public.admin_dashboard_active_subscriptions(json);
DROP FUNCTION IF EXISTS public.admin_dashboard_pending_subscription_requests(json);
DROP FUNCTION IF EXISTS public.my_account_id_rpc(json);

DROP VIEW IF EXISTS public.v_admin_dashboard_account_members;
DROP VIEW IF EXISTS public.v_admin_dashboard_account_member_counts;
DROP VIEW IF EXISTS public.v_admin_dashboard_audit_tail;
DROP VIEW IF EXISTS public.v_admin_dashboard_revenue_monthly;
DROP VIEW IF EXISTS public.v_admin_dashboard_payments;
DROP VIEW IF EXISTS public.v_admin_dashboard_active_subscriptions;
DROP VIEW IF EXISTS public.v_admin_dashboard_pending_subscription_requests;

COMMIT;
