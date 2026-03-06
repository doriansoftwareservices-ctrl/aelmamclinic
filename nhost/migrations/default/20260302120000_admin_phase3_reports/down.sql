-- Rollback Phase 3
DROP VIEW IF EXISTS public.v_admin_usage_daily;
DROP VIEW IF EXISTS public.v_admin_audit_top_actors;
DROP VIEW IF EXISTS public.v_admin_audit_activity_daily;
DROP FUNCTION IF EXISTS public.admin_risk_alerts();
DROP FUNCTION IF EXISTS public.admin_usage_metrics();
