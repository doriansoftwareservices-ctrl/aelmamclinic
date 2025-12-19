---------------------------
---------------------------
---------------------------
-- 2) super_admins: تفعيل RLS + سياسات
---------------------------
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage.objects not found; skipping storage.objects policy changes';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_select_self'
  ) THEN
    CREATE POLICY super_admins_select_self
    ON public.super_admins
    FOR SELECT
    TO PUBLIC
    USING (user_uid = public.request_uid_text()::uuid);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_read_service'
  ) THEN
    CREATE POLICY super_admins_read_service
    ON public.super_admins
    FOR SELECT
    TO public
    USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_write_service'
  ) THEN
    CREATE POLICY super_admins_write_service
    ON public.super_admins
    FOR ALL
    TO public
    USING (true)
    WITH CHECK (true);
  END IF;
END$$;
---------------------------
-- 3) إنشاء جدول account_feature_permissions إن كان مفقودًا
---------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'admin_set_clinic_frozen',
        'admin_create_owner_full',
        'admin_create_employee_full',
        'admin_delete_clinic',
        'admin_attach_employee',
        'admin_bootstrap_clinic_for_email',
        'admin_list_clinics'
      )
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s', r.sig);
  END LOOP;
END;
$$;
CREATE TABLE IF NOT EXISTS public.account_feature_permissions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id       uuid NOT NULL,
  user_uid         uuid NOT NULL,
  allowed_features text[] NOT NULL DEFAULT '{}',
  can_create       boolean NOT NULL DEFAULT true,
  can_update       boolean NOT NULL DEFAULT true,
  can_delete       boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS account_feature_permissions_uix
  ON public.account_feature_permissions (account_id, user_uid);
-- (اختياري) علاقات مرجعية إن كانت موجودة لديك
-- ALTER TABLE public.account_feature_permissions
--   ADD CONSTRAINT account_feature_permissions_account_fk
--   FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;

ALTER TABLE public.account_feature_permissions ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION public.tg_account_feature_permissions_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS account_feature_permissions_touch ON public.account_feature_permissions;
CREATE TRIGGER account_feature_permissions_touch
BEFORE UPDATE ON public.account_feature_permissions
FOR EACH ROW
EXECUTE FUNCTION public.tg_account_feature_permissions_touch();
DO $$
BEGIN
  -- قراءة المالك/العضو أو السوبر أدمن
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_select_members'
  ) THEN
    CREATE POLICY afp_select_members
    ON public.account_feature_permissions
    FOR SELECT
    TO PUBLIC
    USING (
      EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_feature_permissions.account_id
          AND au.user_uid   = public.request_uid_text()::uuid
      )
      OR EXISTS (SELECT 1 FROM public.super_admins sa WHERE sa.user_uid = public.request_uid_text()::uuid)
    );
  END IF;

  -- إدارة الصلاحيات للمالكين/المديرين أو السوبر أدمن
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_manage_account_admins_insert'
  ) THEN
    CREATE POLICY afp_manage_account_admins_insert
    ON public.account_feature_permissions
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_feature_permissions.account_id
          AND au.user_uid   = public.request_uid_text()::uuid
          AND coalesce(au.disabled, false) = false
          AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_manage_account_admins_update'
  ) THEN
    CREATE POLICY afp_manage_account_admins_update
    ON public.account_feature_permissions
    FOR UPDATE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_feature_permissions.account_id
          AND au.user_uid   = public.request_uid_text()::uuid
          AND coalesce(au.disabled, false) = false
          AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
      )
    )
    WITH CHECK (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_feature_permissions.account_id
          AND au.user_uid   = public.request_uid_text()::uuid
          AND coalesce(au.disabled, false) = false
          AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_manage_account_admins_delete'
  ) THEN
    CREATE POLICY afp_manage_account_admins_delete
    ON public.account_feature_permissions
    FOR DELETE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_feature_permissions.account_id
          AND au.user_uid   = public.request_uid_text()::uuid
          AND coalesce(au.disabled, false) = false
          AND lower(coalesce(au.role, '')) IN ('owner','admin','superadmin')
      )
    );
  END IF;

  -- كتابة عبر service_role فقط
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_write_service'
  ) THEN
    CREATE POLICY afp_write_service
    ON public.account_feature_permissions
    FOR ALL
    TO public
    USING (true)
    WITH CHECK (true);
  END IF;
END$$;
---------------------------
-- 4) RPCs مطلوبة من الواجهة
---------------------------

-- يعيد الملف الشخصي للحساب الحالي
CREATE OR REPLACE FUNCTION public.my_profile()
RETURNS TABLE (
  user_uid   uuid,
  email      text,
  account_id uuid,
  role       text,
  disabled   boolean
)
LANGUAGE sql
SECURITY INVOKER
STABLE
AS $$
  SELECT u.id,
         u.email,
         au.account_id,
         au.role::text,
         au.disabled
  FROM auth.users u
  JOIN public.account_users au ON au.user_uid = u.id
  WHERE u.id = public.request_uid_text()::uuid
  LIMIT 1;
$$;
-- أذونات الميزات للمستخدم داخل حسابه الحالي
CREATE OR REPLACE FUNCTION public.my_feature_permissions()
RETURNS TABLE (
  account_id       uuid,
  allowed_features text[],
  can_create       boolean,
  can_update       boolean,
  can_delete       boolean
)
LANGUAGE sql
SECURITY INVOKER
STABLE
AS $$
  SELECT
    coalesce(afp.account_id, au.account_id) as account_id,
    coalesce(afp.allowed_features, '{}')    as allowed_features,
    coalesce(afp.can_create, true)          as can_create,
    coalesce(afp.can_update, true)          as can_update,
    coalesce(afp.can_delete, true)          as can_delete
  FROM public.account_users au
  LEFT JOIN public.account_feature_permissions afp
    ON afp.account_id = au.account_id AND afp.user_uid = au.user_uid
  WHERE au.user_uid = public.request_uid_text()::uuid
  LIMIT 1;
$$;
---------------------------
-- 5) Storage: bucket وسياسات مرفقات الدردشة
---------------------------
INSERT INTO storage.buckets (id) VALUES ('chat-attachments') ON CONFLICT (id) DO NOTHING;
DO $storage$
DECLARE lacking boolean := false;
BEGIN
  BEGIN
    EXECUTE 'set local role supabase_storage_admin';
  EXCEPTION
    WHEN insufficient_privilege THEN
      lacking := true;
    WHEN undefined_object THEN
      lacking := true;
    WHEN invalid_authorization_specification THEN
      lacking := true;
    WHEN invalid_role_specification THEN
      lacking := true;
    WHEN others THEN
      lacking := true;
  END;

  IF lacking THEN
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY';

  EXECUTE $q$DROP POLICY IF EXISTS chat_read_by_participants ON storage.objects$q$;
  EXECUTE $q$
    CREATE POLICY chat_read_by_participants
    ON storage.objects
    FOR SELECT
    TO PUBLIC
    USING (
      bucket_id = 'chat-attachments'
      AND EXISTS (
        SELECT 1
        FROM public.chat_attachments a
        JOIN public.chat_messages m ON m.id = a.message_id
        JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
        WHERE a.bucket = 'chat-attachments'
          AND a.path   = storage.objects.name
          AND p.user_uid = public.request_uid_text()::uuid
      )
    );
  $q$;

  EXECUTE $q$DROP POLICY IF EXISTS chat_write_service_only ON storage.objects$q$;
  EXECUTE $q$
    CREATE POLICY chat_write_service_only
    ON storage.objects
    FOR ALL
    TO public
    USING (bucket_id = 'chat-attachments')
    WITH CHECK (bucket_id = 'chat-attachments');
  $q$;

  EXECUTE 'reset role';
END
$storage$;
---------------------------
-- 6) نشر Realtime لكل جداول public (تدريجيًا)
---------------------------
DO $$
DECLARE
  r record;
BEGIN
  BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
      BEGIN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', r.tablename);
      EXCEPTION
        WHEN duplicate_object THEN
          -- الجدول مضاف مسبقًا إلى الـ publication، نتجاهل الخطأ.
          NULL;
      END;
    END LOOP;
  EXCEPTION
    WHEN undefined_object THEN
      -- publication missing, skip
      NULL;
  END;
END;
$$;
---------------------------
-- 7) chat_participants: أعمدة email/joined_at للتماشي مع التطبيق
---------------------------
ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS joined_at timestamptz;
UPDATE public.chat_participants AS cp
SET joined_at = COALESCE(cp.joined_at, cc.created_at, now())
FROM public.chat_conversations AS cc
WHERE cp.conversation_id = cc.id
  AND cp.joined_at IS NULL;
ALTER TABLE public.chat_participants
  ALTER COLUMN joined_at SET DEFAULT now();
ALTER TABLE public.chat_participants
  ALTER COLUMN joined_at SET NOT NULL;
---------------------------
-- 8) إنشاء جدول audit_logs وسياسات القراءة
---------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id          bigserial PRIMARY KEY,
  account_id  uuid NOT NULL,
  actor_uid   uuid,
  actor_email text,
  table_name  text NOT NULL,
  op          text NOT NULL,
  row_pk      text,
  before_row  jsonb,
  after_row   jsonb,
  diff        jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_logs_account_created_idx
  ON public.audit_logs (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_table_idx
  ON public.audit_logs (table_name);
CREATE INDEX IF NOT EXISTS audit_logs_actor_idx
  ON public.audit_logs (actor_uid);
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON TABLE public.audit_logs TO PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.audit_logs TO public;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_select_account_members'
  ) THEN
    CREATE POLICY audit_logs_select_account_members
    ON public.audit_logs
    FOR SELECT
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = audit_logs.account_id
          AND au.user_uid = public.request_uid_text()::uuid
          AND coalesce(au.disabled, false) = false
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_service_all'
  ) THEN
    CREATE POLICY audit_logs_service_all
    ON public.audit_logs
    FOR ALL
    TO public
    USING (true)
    WITH CHECK (true);
  END IF;
END$$;
---------------------------
-- 9) إجراءات مساعدة للإدارة (RPC)
---------------------------

CREATE OR REPLACE FUNCTION public.admin_list_clinics()
RETURNS TABLE (
  id uuid,
  name text,
  frozen boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
BEGIN
  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT a.id, a.name, a.frozen, a.created_at
  FROM public.accounts a
  ORDER BY a.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_clinics() FROM public;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO PUBLIC;
CREATE OR REPLACE FUNCTION public.admin_set_clinic_frozen(
  p_account_id uuid,
  p_frozen boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
  updated_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.accounts
     SET frozen = coalesce(p_frozen, false)
   WHERE id = p_account_id
   RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', updated_id::text, 'frozen', coalesce(p_frozen, false));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO PUBLIC;
CREATE OR REPLACE FUNCTION public.admin_delete_clinic(
  p_account_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
  deleted_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.accounts
   WHERE id = p_account_id
   RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', deleted_id::text);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_delete_clinic(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO PUBLIC;
CREATE OR REPLACE FUNCTION public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
  owner_uid uuid;
  account_id uuid;
BEGIN
  IF coalesce(trim(p_clinic_name), '') = '' OR coalesce(trim(p_owner_email), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'clinic_name and owner_email are required');
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO owner_uid
  FROM auth.users
  WHERE lower(email) = lower(p_owner_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF owner_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'owner user not found');
  END IF;

  INSERT INTO public.accounts(name, frozen)
  VALUES (p_clinic_name, false)
  RETURNING id INTO account_id;

  PERFORM public.admin_attach_employee(account_id, owner_uid, 'owner');

  UPDATE public.account_users au
     SET email = lower(p_owner_email)
   WHERE au.account_id = account_id
     AND au.user_uid = owner_uid;

  RETURN jsonb_build_object('ok', true, 'account_id', account_id::text, 'owner_uid', owner_uid::text);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_owner_full(text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO PUBLIC;
CREATE OR REPLACE FUNCTION public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub', '')::uuid;
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
  can_manage boolean;
  employee_uid uuid;
BEGIN
  IF p_account IS NULL OR coalesce(trim(p_email), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account and email are required');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid = caller_uid
      AND au.role IN ('owner', 'admin')
      AND coalesce(au.disabled, false) = false
  ) INTO can_manage;

  IF NOT (fn_is_super_admin() = true OR can_manage OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO employee_uid
  FROM auth.users
  WHERE lower(email) = lower(p_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF employee_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user not found');
  END IF;

  PERFORM public.admin_attach_employee(p_account, employee_uid, 'employee');

  UPDATE public.account_users
     SET email = coalesce(email, lower(p_email))
   WHERE account_id = p_account
     AND user_uid = employee_uid;

  RETURN jsonb_build_object('ok', true, 'account_id', p_account::text, 'user_uid', employee_uid::text);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
CREATE OR REPLACE FUNCTION public.chat_admin_start_dm(
  target_email text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub', '')::uuid;
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'admin@elmam.com';
  normalized_email text := lower(coalesce(target_email, ''));
  target_uid uuid;
  target_account uuid;
  existing_conv uuid;
  conv_id uuid;
  now_ts timestamptz := now();
BEGIN
  IF caller_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'target_email is required';
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO target_uid
  FROM auth.users
  WHERE lower(email) = normalized_email
  ORDER BY created_at DESC
  LIMIT 1;

  IF target_uid IS NULL THEN
    RAISE EXCEPTION 'target user not found' USING errcode = 'P0002';
  END IF;

  IF target_uid = caller_uid THEN
    RAISE EXCEPTION 'cannot start conversation with yourself';
  END IF;

  SELECT au.account_id
    INTO target_account
  FROM public.account_users au
  WHERE au.user_uid = target_uid
    AND coalesce(au.disabled, false) = false
  ORDER BY CASE WHEN lower(coalesce(au.role, '')) IN ('owner','admin','superadmin') THEN 0 ELSE 1 END,
           au.created_at DESC
  LIMIT 1;

  SELECT p.conversation_id
    INTO existing_conv
  FROM public.chat_participants p
  JOIN public.chat_participants p2
    ON p.conversation_id = p2.conversation_id
  JOIN public.chat_conversations c
    ON c.id = p.conversation_id
  WHERE p.user_uid = caller_uid
    AND p2.user_uid = target_uid
    AND coalesce(c.is_group, false) = false
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF existing_conv IS NOT NULL THEN
    RETURN existing_conv;
  END IF;

  conv_id := gen_random_uuid();

  INSERT INTO public.chat_conversations(id, account_id, is_group, title, created_by, created_at, updated_at)
  VALUES (conv_id, target_account, false, NULL, caller_uid, now_ts, now_ts);

  INSERT INTO public.chat_participants(conversation_id, user_uid, role, email, joined_at)
  VALUES
    (conv_id, caller_uid, 'superadmin', NULLIF(caller_email, ''), now_ts),
    (conv_id, target_uid, NULL, normalized_email, now_ts);

  RETURN conv_id;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_admin_start_dm(text) FROM public;
GRANT EXECUTE ON FUNCTION public.chat_admin_start_dm(text) TO PUBLIC;
