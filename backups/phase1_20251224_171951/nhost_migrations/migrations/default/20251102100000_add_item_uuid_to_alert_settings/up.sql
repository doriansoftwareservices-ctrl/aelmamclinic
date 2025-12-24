-- 20251102100000_add_item_uuid_to_alert_settings.sql
-- Adds item_uuid column to alert_settings for linking with remote inventory items.

ALTER TABLE IF EXISTS public.alert_settings
  ADD COLUMN IF NOT EXISTS item_uuid uuid;

CREATE INDEX IF NOT EXISTS idx_alert_settings_item_uuid
  ON public.alert_settings(item_uuid);
