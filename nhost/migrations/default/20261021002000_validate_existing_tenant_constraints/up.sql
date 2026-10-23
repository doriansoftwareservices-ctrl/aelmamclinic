BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
-- Read-only anti-joins on 2026-10-21 found zero violations for all 33
-- existing NOT VALID constraints. PostgreSQL performs its own validation here.
-- No rows, identities, financial amounts, or existing constraint definitions
-- are rewritten. Concurrent new writes already obey these constraints.
ALTER TABLE "public"."alert_settings" VALIDATE CONSTRAINT "alert_settings_item_same_account_fk";
ALTER TABLE "public"."alert_settings" VALIDATE CONSTRAINT "alert_settings_item_uuid_same_account_fk";
ALTER TABLE "public"."appointments" VALIDATE CONSTRAINT "appointments_doctor_same_account_fk";
ALTER TABLE "public"."appointments" VALIDATE CONSTRAINT "appointments_patient_same_account_fk";
ALTER TABLE "public"."client_mutations" VALIDATE CONSTRAINT "client_mutations_account_fk";
ALTER TABLE "public"."complaint_questions" VALIDATE CONSTRAINT "clinical_question_template_tenant_fk";
ALTER TABLE "public"."consumptions" VALIDATE CONSTRAINT "consumptions_item_same_account_fk";
ALTER TABLE "public"."consumptions" VALIDATE CONSTRAINT "consumptions_patient_same_account_fk";
ALTER TABLE "public"."doctors" VALIDATE CONSTRAINT "doctors_employee_same_account_fk";
ALTER TABLE "public"."employees_discounts" VALIDATE CONSTRAINT "employees_discounts_employee_same_account_fk";
ALTER TABLE "public"."employees_loans" VALIDATE CONSTRAINT "employees_loans_employee_same_account_fk";
ALTER TABLE "public"."employees_salaries" VALIDATE CONSTRAINT "employees_salaries_employee_same_account_fk";
ALTER TABLE "public"."financial_logs" VALIDATE CONSTRAINT "financial_logs_patient_same_account_fk";
ALTER TABLE "public"."items" VALIDATE CONSTRAINT "items_type_same_account_fk";
ALTER TABLE "public"."patient_complaint_answers" VALIDATE CONSTRAINT "clinical_answer_complaint_tenant_fk";
ALTER TABLE "public"."patient_complaint_answers" VALIDATE CONSTRAINT "clinical_answer_question_tenant_fk";
ALTER TABLE "public"."patient_complaints" VALIDATE CONSTRAINT "clinical_complaint_patient_tenant_fk";
ALTER TABLE "public"."patient_complaints" VALIDATE CONSTRAINT "clinical_complaint_template_tenant_fk";
ALTER TABLE "public"."patient_reports" VALIDATE CONSTRAINT "clinical_report_complaint_patient_fk";
ALTER TABLE "public"."patient_reports" VALIDATE CONSTRAINT "clinical_report_patient_tenant_fk";
ALTER TABLE "public"."patient_services" VALIDATE CONSTRAINT "patient_services_patient_same_account_fk";
ALTER TABLE "public"."patient_services" VALIDATE CONSTRAINT "patient_services_service_same_account_fk";
ALTER TABLE "public"."patients" VALIDATE CONSTRAINT "patients_doctor_same_account_fk";
ALTER TABLE "public"."patients" VALIDATE CONSTRAINT "patients_service_same_account_fk";
ALTER TABLE "public"."prescription_items" VALIDATE CONSTRAINT "prescription_items_drug_same_account_fk";
ALTER TABLE "public"."prescription_items" VALIDATE CONSTRAINT "prescription_items_parent_same_account_fk";
ALTER TABLE "public"."prescriptions" VALIDATE CONSTRAINT "prescriptions_doctor_same_account_fk";
ALTER TABLE "public"."prescriptions" VALIDATE CONSTRAINT "prescriptions_patient_same_account_fk";
ALTER TABLE "public"."purchases" VALIDATE CONSTRAINT "purchases_item_same_account_fk";
ALTER TABLE "public"."purchases" VALIDATE CONSTRAINT "purchases_replacement_account_fk";
ALTER TABLE "public"."service_doctor_share" VALIDATE CONSTRAINT "service_share_doctor_same_account_fk";
ALTER TABLE "public"."service_doctor_share" VALIDATE CONSTRAINT "service_share_service_same_account_fk";
ALTER TABLE "public"."sync_events" VALIDATE CONSTRAINT "sync_events_account_fk";
COMMIT;
