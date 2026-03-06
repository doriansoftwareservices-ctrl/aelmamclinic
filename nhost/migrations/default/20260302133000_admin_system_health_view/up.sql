-- Expose admin_system_health as view for Hasura tracking
CREATE OR REPLACE VIEW public.v_admin_system_health AS
SELECT *
FROM jsonb_to_record(public.admin_system_health()) AS x(
  storage_files bigint,
  chat_attachments bigint,
  pending_subscriptions bigint,
  server_time timestamptz
);
