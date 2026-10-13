BEGIN;

-- DATA-002: preserve legacy preimages, enforce tenant/parent identity on new writes.
-- Existing single-column FKs remain for N-1 GraphQL relationships and delete actions.
CREATE UNIQUE INDEX IF NOT EXISTS patients_clinical_account_id_uq ON public.patients(account_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS complaint_templates_clinical_account_id_uq ON public.complaint_templates(account_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS complaint_questions_clinical_account_id_uq ON public.complaint_questions(account_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS patient_complaints_clinical_account_id_uq ON public.patient_complaints(account_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS patient_complaints_clinical_patient_id_uq ON public.patient_complaints(account_id,patient_id,id);

DO $constraints$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('complaint_questions','clinical_question_template_tenant_fk','(account_id,complaint_id)','complaint_templates','(account_id,id)'),
    ('patient_complaints','clinical_complaint_patient_tenant_fk','(account_id,patient_id)','patients','(account_id,id)'),
    ('patient_complaints','clinical_complaint_template_tenant_fk','(account_id,complaint_id)','complaint_templates','(account_id,id)'),
    ('patient_complaint_answers','clinical_answer_complaint_tenant_fk','(account_id,patient_complaint_id)','patient_complaints','(account_id,id)'),
    ('patient_complaint_answers','clinical_answer_question_tenant_fk','(account_id,question_id)','complaint_questions','(account_id,id)'),
    ('patient_reports','clinical_report_patient_tenant_fk','(account_id,patient_id)','patients','(account_id,id)'),
    ('patient_reports','clinical_report_complaint_patient_fk','(account_id,patient_id,patient_complaint_id)','patient_complaints','(account_id,patient_id,id)')
  ) AS entries(child,name,child_columns,parent,parent_columns)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid=format('public.%I',r.child)::regclass AND conname=r.name) THEN
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY %s REFERENCES public.%I %s ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED NOT VALID',
        r.child,r.name,r.child_columns,r.parent,r.parent_columns);
    END IF;
  END LOOP;
END $constraints$;

-- Only proven links are visible to ordinary clinical API roles. IDs only, no PHI.
CREATE OR REPLACE VIEW public.valid_clinical_parent_links WITH (security_barrier=true) AS
SELECT 'complaint_questions'::text AS row_kind,q.id,q.account_id
FROM public.complaint_questions q JOIN public.complaint_templates t ON (t.id,t.account_id)=(q.complaint_id,q.account_id)
UNION ALL
SELECT 'patient_complaints',c.id,c.account_id
FROM public.patient_complaints c JOIN public.patients p ON (p.id,p.account_id)=(c.patient_id,c.account_id)
WHERE (c.complaint_id IS NULL AND nullif(btrim(c.complaint_title_custom),'') IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.complaint_templates t WHERE (t.id,t.account_id)=(c.complaint_id,c.account_id))
UNION ALL
SELECT 'patient_complaint_answers',a.id,a.account_id
FROM public.patient_complaint_answers a
JOIN public.patient_complaints c ON (c.id,c.account_id)=(a.patient_complaint_id,a.account_id)
JOIN public.patients p ON (p.id,p.account_id)=(c.patient_id,c.account_id)
JOIN public.complaint_questions q ON (q.id,q.account_id)=(a.question_id,a.account_id) AND q.complaint_id=c.complaint_id
JOIN public.complaint_templates t ON (t.id,t.account_id)=(q.complaint_id,q.account_id)
UNION ALL
SELECT 'patient_reports',r.id,r.account_id
FROM public.patient_reports r JOIN public.patients p ON (p.id,p.account_id)=(r.patient_id,r.account_id)
WHERE r.patient_complaint_id IS NULL OR EXISTS(
 SELECT 1 FROM public.patient_complaints c WHERE (c.id,c.account_id,c.patient_id)=(r.patient_complaint_id,r.account_id,r.patient_id)
 AND ((c.complaint_id IS NULL AND nullif(btrim(c.complaint_title_custom),'') IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.complaint_templates t WHERE (t.id,t.account_id)=(c.complaint_id,c.account_id))));
REVOKE ALL ON public.valid_clinical_parent_links FROM PUBLIC;
DO $grant$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='nhost_hasura') THEN
  GRANT SELECT ON public.valid_clinical_parent_links TO nhost_hasura;
 END IF;
END $grant$;

CREATE SCHEMA IF NOT EXISTS clinical_integrity_private;
REVOKE ALL ON SCHEMA clinical_integrity_private FROM PUBLIC;
CREATE TABLE IF NOT EXISTS clinical_integrity_private.legacy_link_preimages(
 row_kind text NOT NULL, record_id uuid NOT NULL, account_id uuid,
 preimage jsonb NOT NULL, preimage_sha256 text NOT NULL,
 reason text NOT NULL, quarantined_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(row_kind,record_id,preimage_sha256));
REVOKE ALL ON ALL TABLES IN SCHEMA clinical_integrity_private FROM PUBLIC;
DO $archive$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['complaint_questions','patient_complaints','patient_complaint_answers','patient_reports'] LOOP
  EXECUTE format(
   'INSERT INTO clinical_integrity_private.legacy_link_preimages(row_kind,record_id,account_id,preimage,preimage_sha256,reason)
    SELECT %L,x.id,x.account_id,to_jsonb(x),encode(public.digest(to_jsonb(x)::text,''sha256''),''hex''),''unproven_tenant_or_parent_link''
    FROM public.%I x WHERE NOT EXISTS(SELECT 1 FROM public.valid_clinical_parent_links v WHERE v.row_kind=%L AND v.id=x.id AND v.account_id=x.account_id)
    ON CONFLICT DO NOTHING',t,t,t);
 END LOOP;
END $archive$;

CREATE OR REPLACE FUNCTION public.assert_clinical_parent_link(p_kind text,p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $body$
DECLARE present boolean;
BEGIN
 IF p_kind NOT IN ('complaint_questions','patient_complaints','patient_complaint_answers','patient_reports') THEN
  RAISE EXCEPTION 'unknown_clinical_row_kind' USING ERRCODE='22023';
 END IF;
 -- Row locks close the concurrent insert/reparent write-skew window.
 EXECUTE format('SELECT true FROM public.%I WHERE id=$1 FOR SHARE',p_kind) INTO present USING p_id;
 IF present THEN
  IF p_kind='complaint_questions' THEN
   PERFORM t.id FROM public.complaint_templates t JOIN public.complaint_questions q ON t.id=q.complaint_id WHERE q.id=p_id FOR SHARE OF t;
  ELSIF p_kind='patient_complaints' THEN
   PERFORM p.id FROM public.patients p JOIN public.patient_complaints c ON p.id=c.patient_id WHERE c.id=p_id FOR SHARE OF p;
   PERFORM t.id FROM public.complaint_templates t JOIN public.patient_complaints c ON t.id=c.complaint_id WHERE c.id=p_id FOR SHARE OF t;
  ELSIF p_kind='patient_complaint_answers' THEN
   PERFORM c.id,q.id FROM public.patient_complaint_answers a JOIN public.patient_complaints c ON c.id=a.patient_complaint_id JOIN public.complaint_questions q ON q.id=a.question_id WHERE a.id=p_id FOR SHARE OF c,q;
   PERFORM p.id,t.id FROM public.patient_complaint_answers a JOIN public.patient_complaints c ON c.id=a.patient_complaint_id JOIN public.patients p ON p.id=c.patient_id JOIN public.complaint_templates t ON t.id=c.complaint_id WHERE a.id=p_id FOR SHARE OF p,t;
  ELSIF p_kind='patient_reports' THEN
   PERFORM p.id FROM public.patients p JOIN public.patient_reports r ON p.id=r.patient_id WHERE r.id=p_id FOR SHARE OF p;
   PERFORM c.id FROM public.patient_complaints c JOIN public.patient_reports r ON c.id=r.patient_complaint_id WHERE r.id=p_id FOR SHARE OF c;
   PERFORM t.id FROM public.complaint_templates t JOIN public.patient_complaints c ON t.id=c.complaint_id JOIN public.patient_reports r ON c.id=r.patient_complaint_id WHERE r.id=p_id FOR SHARE OF t;
  END IF;
 END IF;
 IF present AND NOT EXISTS(SELECT 1 FROM public.valid_clinical_parent_links WHERE row_kind=p_kind AND id=p_id) THEN
  RAISE EXCEPTION 'clinical_parent_identity_mismatch: %',p_kind USING ERRCODE='23514';
 END IF;
END $body$;
REVOKE ALL ON FUNCTION public.assert_clinical_parent_link(text,uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.enforce_clinical_parent_links()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $body$
DECLARE r record; changed boolean:=false;
BEGIN
 IF TG_TABLE_NAME IN ('complaint_questions','patient_complaints','patient_complaint_answers','patient_reports') THEN
  PERFORM public.assert_clinical_parent_link(TG_TABLE_NAME,NEW.id);
 END IF;
 IF TG_OP='UPDATE' THEN
  IF TG_TABLE_NAME IN ('patients','complaint_templates') THEN
   changed:=(NEW.id,NEW.account_id) IS DISTINCT FROM (OLD.id,OLD.account_id);
  ELSIF TG_TABLE_NAME='complaint_questions' THEN
   changed:=(NEW.id,NEW.account_id,NEW.complaint_id) IS DISTINCT FROM (OLD.id,OLD.account_id,OLD.complaint_id);
  ELSIF TG_TABLE_NAME='patient_complaints' THEN
   changed:=(NEW.id,NEW.account_id,NEW.patient_id,NEW.complaint_id) IS DISTINCT FROM (OLD.id,OLD.account_id,OLD.patient_id,OLD.complaint_id);
  END IF;
 END IF;
 IF changed THEN
  IF TG_TABLE_NAME='patients' THEN
   FOR r IN SELECT 'patient_complaints'::text AS kind,id FROM public.patient_complaints WHERE patient_id IN(OLD.id,NEW.id)
    UNION ALL SELECT 'patient_reports',id FROM public.patient_reports WHERE patient_id IN(OLD.id,NEW.id)
    UNION ALL SELECT 'patient_complaint_answers',a.id FROM public.patient_complaint_answers a JOIN public.patient_complaints c ON c.id=a.patient_complaint_id WHERE c.patient_id IN(OLD.id,NEW.id)
   LOOP PERFORM public.assert_clinical_parent_link(r.kind,r.id); END LOOP;
  ELSIF TG_TABLE_NAME='complaint_templates' THEN
   FOR r IN SELECT 'complaint_questions'::text AS kind,id FROM public.complaint_questions WHERE complaint_id IN(OLD.id,NEW.id)
    UNION ALL SELECT 'patient_complaints',id FROM public.patient_complaints WHERE complaint_id IN(OLD.id,NEW.id)
    UNION ALL SELECT 'patient_complaint_answers',a.id FROM public.patient_complaint_answers a JOIN public.complaint_questions q ON q.id=a.question_id WHERE q.complaint_id IN(OLD.id,NEW.id)
    UNION ALL SELECT 'patient_reports',x.id FROM public.patient_reports x JOIN public.patient_complaints c ON c.id=x.patient_complaint_id WHERE c.complaint_id IN(OLD.id,NEW.id)
   LOOP PERFORM public.assert_clinical_parent_link(r.kind,r.id); END LOOP;
  ELSIF TG_TABLE_NAME='complaint_questions' THEN
   FOR r IN SELECT id FROM public.patient_complaint_answers WHERE question_id IN(OLD.id,NEW.id)
   LOOP PERFORM public.assert_clinical_parent_link('patient_complaint_answers',r.id); END LOOP;
  ELSIF TG_TABLE_NAME='patient_complaints' THEN
   FOR r IN SELECT 'patient_complaint_answers'::text AS kind,id FROM public.patient_complaint_answers WHERE patient_complaint_id IN(OLD.id,NEW.id)
    UNION ALL SELECT 'patient_reports',id FROM public.patient_reports WHERE patient_complaint_id IN(OLD.id,NEW.id)
   LOOP PERFORM public.assert_clinical_parent_link(r.kind,r.id); END LOOP;
  END IF;
 END IF;
 RETURN NULL;
END $body$;
REVOKE ALL ON FUNCTION public.enforce_clinical_parent_links() FROM PUBLIC;

DO $triggers$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['patients','complaint_templates','complaint_questions','patient_complaints','patient_complaint_answers','patient_reports'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS clinical_parent_links_guard ON public.%I',t);
  EXECUTE format('CREATE CONSTRAINT TRIGGER clinical_parent_links_guard AFTER INSERT OR UPDATE ON public.%I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_clinical_parent_links()',t);
 END LOOP;
END $triggers$;

-- Preserve the clinical complaint title before the existing SET NULL delete action.
CREATE OR REPLACE FUNCTION public.capture_deleted_clinical_template_title()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $body$
BEGIN
 UPDATE public.patient_complaints SET complaint_title_custom=OLD.title
 WHERE complaint_id=OLD.id AND account_id=OLD.account_id AND nullif(btrim(complaint_title_custom),'') IS NULL;
 RETURN OLD;
END $body$;
REVOKE ALL ON FUNCTION public.capture_deleted_clinical_template_title() FROM PUBLIC;
DROP TRIGGER IF EXISTS clinical_template_title_before_delete ON public.complaint_templates;
CREATE TRIGGER clinical_template_title_before_delete BEFORE DELETE ON public.complaint_templates
FOR EACH ROW EXECUTE FUNCTION public.capture_deleted_clinical_template_title();
COMMIT;
