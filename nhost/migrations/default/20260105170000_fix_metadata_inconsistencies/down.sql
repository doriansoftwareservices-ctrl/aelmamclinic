BEGIN;

-- Intentionally keep schema additions to avoid destructive rollback.
-- Drop only the admin/dashboard functions and my_account_id_rpc we recreated.

DROP FUNCTION IF EXISTS public.admin_dashboard_account_members(json, uuid, boolean);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_member_counts(json, boolean);
DROP FUNCTION IF EXISTS public.admin_dashboard_audit_tail(json, uuid, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_revenue_monthly(json, integer);
DROP FUNCTION IF EXISTS public.admin_dashboard_payments(json, timestamptz);
DROP FUNCTION IF EXISTS public.admin_dashboard_active_subscriptions(json);
DROP FUNCTION IF EXISTS public.admin_dashboard_pending_subscription_requests(json);
DROP FUNCTION IF EXISTS public.my_account_id_rpc(json);

COMMIT;
