-- Phase 1 core admin analytics + action logs
-- Safe for re-run (idempotent where possible).

-- ---------------------------------------------------------------------------
-- 1) Admin action logs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_action_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_uid uuid NOT NULL,
  actor_email text,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id text,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_action_logs_created_at_idx
  ON public.admin_action_logs (created_at DESC);

ALTER TABLE public.admin_action_logs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='admin_action_logs'
      AND policyname='admin_action_logs_select_super'
  ) THEN
    CREATE POLICY admin_action_logs_select_super
      ON public.admin_action_logs
      FOR SELECT
      TO PUBLIC
      USING (fn_is_super_admin() = true);
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='admin_action_logs'
      AND policyname='admin_action_logs_insert_super'
  ) THEN
    CREATE POLICY admin_action_logs_insert_super
      ON public.admin_action_logs
      FOR INSERT
      TO PUBLIC
      WITH CHECK (fn_is_super_admin() = true);
  END IF;
END$$;

-- Helper to log admin actions (superadmin only)
CREATE OR REPLACE FUNCTION public.admin_log_action(
  p_action text,
  p_entity_type text,
  p_entity_id text DEFAULT NULL,
  p_details jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;
  IF fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;
  SELECT email INTO v_email FROM auth.users WHERE id = v_uid;
  INSERT INTO public.admin_action_logs(
    actor_uid, actor_email, action, entity_type, entity_id, details
  ) VALUES (
    v_uid, v_email, p_action, p_entity_type, p_entity_id, p_details
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) System health (basic snapshot)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_system_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
  v_storage_files bigint := 0;
  v_chat_atts bigint := 0;
  v_sub_pending bigint := 0;
BEGIN
  IF to_regclass('storage.files') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM storage.files' INTO v_storage_files;
  END IF;
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.chat_attachments' INTO v_chat_atts;
  END IF;
  IF to_regclass('public.subscription_requests') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.subscription_requests WHERE status = ''pending'''
      INTO v_sub_pending;
  END IF;
  RETURN jsonb_build_object(
    'storage_files', v_storage_files,
    'chat_attachments', v_chat_atts,
    'pending_subscriptions', v_sub_pending,
    'server_time', now()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Revenue analytics (MRR/ARR from approved requests)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.subscription_requests') IS NOT NULL THEN
    EXECUTE $view$
      CREATE OR REPLACE VIEW public.v_admin_mrr_by_month AS
      SELECT
        date_trunc('month', created_at) AS month,
        SUM(COALESCE(amount, 0))::numeric AS mrr
      FROM public.subscription_requests
      WHERE status = 'approved'
      GROUP BY 1
      ORDER BY 1 DESC;
    $view$;

    EXECUTE $view$
      CREATE OR REPLACE VIEW public.v_admin_arr_by_month AS
      SELECT
        month,
        (mrr * 12)::numeric AS arr
      FROM public.v_admin_mrr_by_month;
    $view$;
  END IF;
END$$;
