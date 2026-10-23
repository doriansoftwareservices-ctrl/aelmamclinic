DO $$ BEGIN RAISE EXCEPTION 'notification_source_outbox_v2_requires_forward_fix_preserve_source_events_and_targets'; END $$;
