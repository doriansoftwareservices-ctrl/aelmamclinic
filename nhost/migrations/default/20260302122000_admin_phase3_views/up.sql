-- Phase 3 fix: expose usage metrics & risk alerts as views (trackable by Hasura)

CREATE OR REPLACE VIEW public.v_admin_usage_metrics AS
SELECT *
FROM jsonb_to_record(public.admin_usage_metrics()) AS x(
  accounts bigint,
  account_users bigint,
  chat_messages_30d bigint,
  chat_attachments bigint,
  audit_events_7d bigint,
  active_users_30d bigint,
  server_time timestamptz
);

CREATE OR REPLACE VIEW public.v_admin_risk_alerts AS
SELECT *
FROM jsonb_to_recordset(
  COALESCE(public.admin_risk_alerts(), '[]'::jsonb)
) AS x(
  code text,
  severity text,
  title text,
  count bigint,
  hint text
);
