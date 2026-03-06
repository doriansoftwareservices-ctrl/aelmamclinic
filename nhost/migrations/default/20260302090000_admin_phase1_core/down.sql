-- Phase 1 core admin analytics + action logs (rollback)

DROP VIEW IF EXISTS public.v_admin_arr_by_month;
DROP VIEW IF EXISTS public.v_admin_mrr_by_month;

DROP FUNCTION IF EXISTS public.admin_system_health();
DROP FUNCTION IF EXISTS public.admin_log_action(text, text, text, jsonb);

DROP TABLE IF EXISTS public.admin_action_logs;
