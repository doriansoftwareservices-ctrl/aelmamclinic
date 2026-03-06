BEGIN;

-- Ensure core chat_attachments table exists (some environments may have dropped it)
CREATE TABLE IF NOT EXISTS public.chat_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id uuid NOT NULL,
  bucket text NOT NULL DEFAULT 'chat-images',
  path text NOT NULL,
  mime_type text,
  size_bytes integer,
  width integer,
  height integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id text,
  local_id bigint
);

-- Ensure FK to chat_messages if possible
DO $$
BEGIN
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chat_attachments_message_id_fkey') THEN
      ALTER TABLE public.chat_attachments
        ADD CONSTRAINT chat_attachments_message_id_fkey
        FOREIGN KEY (message_id)
        REFERENCES public.chat_messages(id)
        ON DELETE CASCADE;
    END IF;
  END IF;
END$$;

-- ---------------------------------------------------------------------------
-- 1) Devices registry (per-user devices)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_user_devices (
  user_uid uuid NOT NULL,
  device_id text NOT NULL,
  platform text,
  app_version text,
  last_seen timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_uid, device_id)
);

CREATE INDEX IF NOT EXISTS chat_user_devices_last_seen_idx
  ON public.chat_user_devices(user_uid, last_seen DESC);

ALTER TABLE public.chat_user_devices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_user_devices_select_self ON public.chat_user_devices;
CREATE POLICY chat_user_devices_select_self
  ON public.chat_user_devices
  FOR SELECT
  TO PUBLIC
  USING (
    fn_is_super_admin() = true
    OR user_uid::text = public.request_uid_text()::text
  );

DROP POLICY IF EXISTS chat_user_devices_write_self ON public.chat_user_devices;
CREATE POLICY chat_user_devices_write_self
  ON public.chat_user_devices
  FOR ALL
  TO PUBLIC
  USING (
    fn_is_super_admin() = true
    OR user_uid::text = public.request_uid_text()::text
  )
  WITH CHECK (
    fn_is_super_admin() = true
    OR user_uid::text = public.request_uid_text()::text
  );

-- ---------------------------------------------------------------------------
-- 2) Targets per attachment (snapshot of devices at send time)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_attachment_targets (
  attachment_id uuid NOT NULL REFERENCES public.chat_attachments(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  device_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (attachment_id, user_uid, device_id)
);

CREATE INDEX IF NOT EXISTS chat_att_targets_att_idx
  ON public.chat_attachment_targets(attachment_id);

ALTER TABLE public.chat_attachment_targets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_attachment_targets_select_member ON public.chat_attachment_targets;
CREATE POLICY chat_attachment_targets_select_member
  ON public.chat_attachment_targets
  FOR SELECT
  TO PUBLIC
  USING (
    fn_is_super_admin() = true
    OR EXISTS (
      SELECT 1
      FROM public.chat_attachments a
      JOIN public.chat_messages m ON m.id = a.message_id
      JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
      WHERE a.id = chat_attachment_targets.attachment_id
        AND p.user_uid::text = public.request_uid_text()::text
    )
  );

DROP POLICY IF EXISTS chat_attachment_targets_write_admin ON public.chat_attachment_targets;
CREATE POLICY chat_attachment_targets_write_admin
  ON public.chat_attachment_targets
  FOR ALL
  TO PUBLIC
  USING (fn_is_super_admin() = true)
  WITH CHECK (fn_is_super_admin() = true);

-- ---------------------------------------------------------------------------
-- 3) Receipts per attachment (download/open)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_attachment_receipts (
  attachment_id uuid NOT NULL REFERENCES public.chat_attachments(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  device_id text NOT NULL,
  downloaded_at timestamptz,
  opened_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (attachment_id, user_uid, device_id)
);

CREATE INDEX IF NOT EXISTS chat_att_receipts_att_idx
  ON public.chat_attachment_receipts(attachment_id);

ALTER TABLE public.chat_attachment_receipts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_attachment_receipts_select_member ON public.chat_attachment_receipts;
CREATE POLICY chat_attachment_receipts_select_member
  ON public.chat_attachment_receipts
  FOR SELECT
  TO PUBLIC
  USING (
    fn_is_super_admin() = true
    OR user_uid::text = public.request_uid_text()::text
    OR EXISTS (
      SELECT 1
      FROM public.chat_attachments a
      JOIN public.chat_messages m ON m.id = a.message_id
      JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
      WHERE a.id = chat_attachment_receipts.attachment_id
        AND p.user_uid::text = public.request_uid_text()::text
    )
  );

DROP POLICY IF EXISTS chat_attachment_receipts_write_self ON public.chat_attachment_receipts;
CREATE POLICY chat_attachment_receipts_write_self
  ON public.chat_attachment_receipts
  FOR ALL
  TO PUBLIC
  USING (
    fn_is_super_admin() = true
    OR user_uid::text = public.request_uid_text()::text
  )
  WITH CHECK (
    fn_is_super_admin() = true
    OR user_uid::text = public.request_uid_text()::text
  );

-- ---------------------------------------------------------------------------
-- 4) Columns on chat_attachments for purge scheduling
-- ---------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.chat_attachments
  ADD COLUMN IF NOT EXISTS purge_ready boolean NOT NULL DEFAULT false;
ALTER TABLE IF EXISTS public.chat_attachments
  ADD COLUMN IF NOT EXISTS purge_at timestamptz;

CREATE INDEX IF NOT EXISTS chat_attachments_purge_idx
  ON public.chat_attachments(purge_ready, purge_at);

-- ---------------------------------------------------------------------------
-- 5) Support conversation helper (exclude from purge)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_is_support_conversation(p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_participants p
    JOIN public.chat_support_agents a
      ON a.user_uid = p.user_uid AND a.is_active = true
    WHERE p.conversation_id = p_conversation_id
  );
$$;

-- ---------------------------------------------------------------------------
-- 6) Register device (heartbeat)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_register_device(
  p_device_id text,
  p_platform text DEFAULT NULL,
  p_app_version text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF v_uid IS NULL OR p_device_id IS NULL OR btrim(p_device_id) = '' THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;

  INSERT INTO public.chat_user_devices(user_uid, device_id, platform, app_version, last_seen)
  VALUES (v_uid, btrim(p_device_id), p_platform, p_app_version, now())
  ON CONFLICT (user_uid, device_id)
  DO UPDATE SET
    platform = EXCLUDED.platform,
    app_version = EXCLUDED.app_version,
    last_seen = now();
END;
$$;

-- ---------------------------------------------------------------------------
-- 7) Trigger: create targets on attachment insert (snapshot of active devices)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_chat_attachments_create_targets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cid uuid;
BEGIN
  SELECT m.conversation_id INTO v_cid
  FROM public.chat_messages m
  WHERE m.id = NEW.message_id;

  IF v_cid IS NULL THEN
    RETURN NEW;
  END IF;

  -- Skip support conversations
  IF public.chat_is_support_conversation(v_cid) THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.chat_attachment_targets(attachment_id, user_uid, device_id)
  SELECT NEW.id, p.user_uid, d.device_id
  FROM public.chat_participants p
  JOIN public.chat_user_devices d
    ON d.user_uid = p.user_uid
   AND d.last_seen >= now() - interval '30 days'
  WHERE p.conversation_id = v_cid
    AND COALESCE(p.is_deleted, false) = false
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_attachments_create_targets ON public.chat_attachments;
CREATE TRIGGER chat_attachments_create_targets
AFTER INSERT ON public.chat_attachments
FOR EACH ROW
EXECUTE FUNCTION public.tg_chat_attachments_create_targets();

-- ---------------------------------------------------------------------------
-- 8) Schedule purge when all devices have downloaded+opened
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_try_schedule_attachment_purge(
  p_attachment_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security TO 'off'
AS $$
DECLARE
  v_bucket text;
  v_path text;
  v_cid uuid;
  v_missing int;
  v_max_ack timestamptz;
BEGIN
  SELECT a.bucket, a.path, m.conversation_id
    INTO v_bucket, v_path, v_cid
  FROM public.chat_attachments a
  JOIN public.chat_messages m ON m.id = a.message_id
  WHERE a.id = p_attachment_id
  LIMIT 1;

  IF v_cid IS NULL THEN
    RETURN false;
  END IF;

  IF public.chat_is_support_conversation(v_cid) THEN
    RETURN false;
  END IF;

  -- Ensure targets exist (safety)
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_attachment_targets t
    WHERE t.attachment_id = p_attachment_id
  ) THEN
    INSERT INTO public.chat_attachment_targets(attachment_id, user_uid, device_id)
    SELECT p_attachment_id, p.user_uid, d.device_id
    FROM public.chat_participants p
    JOIN public.chat_user_devices d
      ON d.user_uid = p.user_uid
     AND d.last_seen >= now() - interval '30 days'
    WHERE p.conversation_id = v_cid
      AND COALESCE(p.is_deleted, false) = false
    ON CONFLICT DO NOTHING;
  END IF;

  -- Check missing receipts
  SELECT count(*) INTO v_missing
  FROM public.chat_attachment_targets t
  LEFT JOIN public.chat_attachment_receipts r
    ON r.attachment_id = t.attachment_id
   AND r.user_uid = t.user_uid
   AND r.device_id = t.device_id
  WHERE t.attachment_id = p_attachment_id
    AND (r.downloaded_at IS NULL OR r.opened_at IS NULL);

  IF v_missing > 0 THEN
    RETURN false;
  END IF;

  SELECT max(greatest(r.downloaded_at, r.opened_at)) INTO v_max_ack
  FROM public.chat_attachment_receipts r
  JOIN public.chat_attachment_targets t
    ON t.attachment_id = r.attachment_id
   AND t.user_uid = r.user_uid
   AND t.device_id = r.device_id
  WHERE r.attachment_id = p_attachment_id;

  IF v_max_ack IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.chat_attachments
  SET purge_ready = true,
      purge_at = v_max_ack + interval '24 hours'
  WHERE id = p_attachment_id;

  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9) Mark downloaded/opened
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_mark_attachment_downloaded(
  p_attachment_id uuid,
  p_device_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_cid uuid;
BEGIN
  IF v_uid IS NULL OR p_attachment_id IS NULL OR btrim(p_device_id) = '' THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;

  SELECT m.conversation_id INTO v_cid
  FROM public.chat_attachments a
  JOIN public.chat_messages m ON m.id = a.message_id
  JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
  WHERE a.id = p_attachment_id
    AND p.user_uid = v_uid
    AND COALESCE(p.is_deleted, false) = false
  LIMIT 1;

  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'not allowed' USING errcode='42501';
  END IF;

  PERFORM public.chat_register_device(p_device_id, NULL, NULL);

  INSERT INTO public.chat_attachment_receipts(
    attachment_id, user_uid, device_id, downloaded_at
  )
  VALUES (p_attachment_id, v_uid, btrim(p_device_id), now())
  ON CONFLICT (attachment_id, user_uid, device_id)
  DO UPDATE SET
    downloaded_at = COALESCE(chat_attachment_receipts.downloaded_at, EXCLUDED.downloaded_at);

  PERFORM public.chat_try_schedule_attachment_purge(p_attachment_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.chat_mark_attachment_opened(
  p_attachment_id uuid,
  p_device_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF v_uid IS NULL OR p_attachment_id IS NULL OR btrim(p_device_id) = '' THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;

  PERFORM public.chat_register_device(p_device_id, NULL, NULL);

  INSERT INTO public.chat_attachment_receipts(
    attachment_id, user_uid, device_id, opened_at
  )
  VALUES (p_attachment_id, v_uid, btrim(p_device_id), now())
  ON CONFLICT (attachment_id, user_uid, device_id)
  DO UPDATE SET
    opened_at = COALESCE(chat_attachment_receipts.opened_at, EXCLUDED.opened_at);

  PERFORM public.chat_try_schedule_attachment_purge(p_attachment_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- 10) Purge due attachments (cron)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_purge_due_attachments(
  p_limit int DEFAULT 200
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
SET row_security TO 'off'
AS $$
DECLARE
  v_count int := 0;
BEGIN
  WITH due AS (
    SELECT a.id, a.bucket, a.path
    FROM public.chat_attachments a
    JOIN public.chat_messages m ON m.id = a.message_id
    WHERE a.purge_ready = true
      AND a.purge_at IS NOT NULL
      AND a.purge_at <= now()
      AND NOT public.chat_is_support_conversation(m.conversation_id)
    ORDER BY a.purge_at
    LIMIT COALESCE(p_limit, 200)
  )
  DELETE FROM storage.files f
  USING due d
  WHERE f.bucket_id = d.bucket
    AND (f.id::text = d.path OR f.name = d.path);

  WITH due AS (
    SELECT a.id
    FROM public.chat_attachments a
    JOIN public.chat_messages m ON m.id = a.message_id
    WHERE a.purge_ready = true
      AND a.purge_at IS NOT NULL
      AND a.purge_at <= now()
      AND NOT public.chat_is_support_conversation(m.conversation_id)
    ORDER BY a.purge_at
    LIMIT COALESCE(p_limit, 200)
  )
  DELETE FROM public.chat_attachments a
  USING due d
  WHERE a.id = d.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMIT;
