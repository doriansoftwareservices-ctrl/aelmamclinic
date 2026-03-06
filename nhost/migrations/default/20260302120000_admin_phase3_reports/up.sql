-- Phase 3: advanced admin reports, risk alerts, and usage monitoring
-- Safe for re-run where possible.

-- ---------------------------------------------------------------------------
-- 1) Usage metrics (JSON)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_usage_metrics()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, storage
AS $$
DECLARE
  v_accounts bigint := 0;
  v_account_users bigint := 0;
  v_chat_messages_30d bigint := 0;
  v_chat_attachments bigint := 0;
  v_audit_7d bigint := 0;
  v_active_users_30d bigint := NULL;
BEGIN
  IF to_regclass('public.accounts') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.accounts' INTO v_accounts;
  END IF;
  IF to_regclass('public.account_users') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.account_users' INTO v_account_users;
  END IF;
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.chat_messages
             WHERE created_at >= now() - interval ''30 days'''
      INTO v_chat_messages_30d;
  END IF;
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.chat_attachments' INTO v_chat_attachments;
  END IF;
  IF to_regclass('public.audit_logs') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.audit_logs
             WHERE created_at >= now() - interval ''7 days'''
      INTO v_audit_7d;
  END IF;

  -- Optional: active users if column exists
  IF to_regclass('auth.users') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='auth' AND table_name='users'
        AND column_name='last_seen_at'
    ) THEN
      EXECUTE 'SELECT count(*) FROM auth.users
               WHERE last_seen_at >= now() - interval ''30 days'''
        INTO v_active_users_30d;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'accounts', v_accounts,
    'account_users', v_account_users,
    'chat_messages_30d', v_chat_messages_30d,
    'chat_attachments', v_chat_attachments,
    'audit_events_7d', v_audit_7d,
    'active_users_30d', v_active_users_30d,
    'server_time', now()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) Risk alerts (JSON array)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_risk_alerts()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
  v_pending_subs bigint := 0;
  v_overdue_purge bigint := 0;
  v_storage_files bigint := 0;
  v_audit_24h bigint := 0;
BEGIN
  IF to_regclass('public.subscription_requests') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.subscription_requests
             WHERE status = ''pending'''
      INTO v_pending_subs;
  END IF;
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.chat_attachments
             WHERE purge_ready = true
               AND purge_at IS NOT NULL
               AND purge_at <= now() - interval ''24 hours'''
      INTO v_overdue_purge;
  END IF;
  IF to_regclass('storage.files') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM storage.files' INTO v_storage_files;
  END IF;
  IF to_regclass('public.audit_logs') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.audit_logs
             WHERE created_at >= now() - interval ''24 hours'''
      INTO v_audit_24h;
  END IF;

  RETURN (
    SELECT jsonb_agg(alert)
    FROM (
      SELECT jsonb_build_object(
        'code','pending_subscriptions',
        'severity','medium',
        'title','طلبات اشتراك معلّقة',
        'count', v_pending_subs,
        'hint','راجع الطلبات المتراكمة ووافق/ارفض.'
      ) AS alert
      WHERE v_pending_subs > 10

      UNION ALL
      SELECT jsonb_build_object(
        'code','overdue_purge',
        'severity','high',
        'title','مرفقات متأخرة عن الحذف',
        'count', v_overdue_purge,
        'hint','تحقق من عمل cron والحذف المؤجل.'
      )
      WHERE v_overdue_purge > 0

      UNION ALL
      SELECT jsonb_build_object(
        'code','storage_growth',
        'severity','medium',
        'title','ارتفاع مساحة التخزين',
        'count', v_storage_files,
        'hint','راجع سياسة الاحتفاظ بالمرفقات.'
      )
      WHERE v_storage_files > 100000

      UNION ALL
      SELECT jsonb_build_object(
        'code','audit_spike',
        'severity','low',
        'title','ارتفاع غير طبيعي في سجلات التدقيق',
        'count', v_audit_24h,
        'hint','تحقق من نشاط غير اعتيادي خلال آخر 24 ساعة.'
      )
      WHERE v_audit_24h > 5000
    ) s(alert)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Views for advanced audit/usage reports
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.audit_logs') IS NOT NULL THEN
    EXECUTE $v$
      CREATE OR REPLACE VIEW public.v_admin_audit_activity_daily AS
      SELECT
        date_trunc('day', created_at) AS day,
        table_name,
        op,
        count(*)::bigint AS events
      FROM public.audit_logs
      GROUP BY 1,2,3
      ORDER BY 1 DESC;
    $v$;

    EXECUTE $v$
      CREATE OR REPLACE VIEW public.v_admin_audit_top_actors AS
      SELECT
        actor_uid,
        actor_email,
        count(*)::bigint AS events,
        max(created_at) AS last_at
      FROM public.audit_logs
      WHERE created_at >= now() - interval '30 days'
      GROUP BY 1,2
      ORDER BY events DESC, last_at DESC;
    $v$;
  END IF;

  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    EXECUTE $v$
      CREATE OR REPLACE VIEW public.v_admin_usage_daily AS
      SELECT
        date_trunc('day', m.created_at) AS day,
        count(distinct m.id)::bigint AS messages,
        count(a.id)::bigint AS attachments
      FROM public.chat_messages m
      LEFT JOIN public.chat_attachments a
        ON a.message_id = m.id
      GROUP BY 1
      ORDER BY 1 DESC;
    $v$;
  END IF;
END$$;
