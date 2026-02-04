-- 20260204190000_patient_complaints_questions_reports.sql
-- Complaint templates/questions, patient complaints/answers, and patient reports.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS public.complaint_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.complaint_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  complaint_id uuid NOT NULL REFERENCES public.complaint_templates(id) ON DELETE CASCADE,
  question_text text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.patient_complaints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  patient_id uuid NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
  complaint_id uuid REFERENCES public.complaint_templates(id) ON DELETE SET NULL,
  complaint_title_custom text,
  status text NOT NULL DEFAULT 'active',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT patient_complaints_complaint_or_custom
    CHECK (
      complaint_id IS NOT NULL OR
      (complaint_title_custom IS NOT NULL AND length(trim(complaint_title_custom)) > 0)
    )
);

CREATE TABLE IF NOT EXISTS public.patient_complaint_answers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  patient_complaint_id uuid NOT NULL REFERENCES public.patient_complaints(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES public.complaint_questions(id) ON DELETE CASCADE,
  answer_bool boolean,
  note_text text,
  answered_by uuid,
  answered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.patient_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  patient_id uuid NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
  patient_complaint_id uuid REFERENCES public.patient_complaints(id) ON DELETE SET NULL,
  report_text text NOT NULL,
  status text NOT NULL DEFAULT 'final',
  snapshot jsonb NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS complaint_templates_account_title_uq
  ON public.complaint_templates (account_id, lower(title));

CREATE INDEX IF NOT EXISTS complaint_templates_account_active_sort_idx
  ON public.complaint_templates (account_id, is_active, sort_order);

CREATE INDEX IF NOT EXISTS complaint_questions_complaint_active_sort_idx
  ON public.complaint_questions (complaint_id, is_active, sort_order);

CREATE UNIQUE INDEX IF NOT EXISTS patient_complaints_patient_complaint_uq
  ON public.patient_complaints (patient_id, complaint_id)
  WHERE complaint_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS patient_complaints_patient_created_idx
  ON public.patient_complaints (patient_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS patient_complaint_answers_uq
  ON public.patient_complaint_answers (patient_complaint_id, question_id);

CREATE INDEX IF NOT EXISTS patient_complaint_answers_complaint_idx
  ON public.patient_complaint_answers (patient_complaint_id);

CREATE INDEX IF NOT EXISTS patient_reports_patient_created_idx
  ON public.patient_reports (patient_id, created_at DESC);

DO $$
DECLARE
  tbl text;
  managed_tables constant text[] := ARRAY[
    'complaint_templates',
    'complaint_questions',
    'patient_complaints',
    'patient_complaint_answers',
    'patient_reports'
  ];
BEGIN
  FOR tbl IN SELECT unnest(managed_tables) LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);

    EXECUTE format('DROP POLICY IF EXISTS %I_select_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_select_member_or_super ON public.%I FOR SELECT TO PUBLIC USING (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl
    );

    EXECUTE format('DROP POLICY IF EXISTS %I_insert_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_insert_member_or_super ON public.%I FOR INSERT TO PUBLIC WITH CHECK (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl
    );

    EXECUTE format('DROP POLICY IF EXISTS %I_update_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_update_member_or_super ON public.%I FOR UPDATE TO PUBLIC USING (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id)) WITH CHECK (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl, tbl
    );

    EXECUTE format('DROP POLICY IF EXISTS %I_delete_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_delete_member_or_super ON public.%I FOR DELETE TO PUBLIC USING (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl
    );
  END LOOP;
END $$;
