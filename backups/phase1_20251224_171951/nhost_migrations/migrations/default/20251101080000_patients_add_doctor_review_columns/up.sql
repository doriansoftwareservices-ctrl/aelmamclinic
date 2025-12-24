-- 20251101080000_patients_add_doctor_review_columns.sql
-- Adds review tracking columns for doctor confirmation workflow.

ALTER TABLE IF EXISTS public.patients
  ADD COLUMN IF NOT EXISTS doctor_review_pending boolean NOT NULL DEFAULT false;

ALTER TABLE IF EXISTS public.patients
  ADD COLUMN IF NOT EXISTS doctor_reviewed_at timestamptz;
