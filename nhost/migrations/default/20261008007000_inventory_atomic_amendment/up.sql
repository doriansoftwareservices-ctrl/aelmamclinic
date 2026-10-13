BEGIN;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS replaces_purchase_id uuid;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS amendment_client_mutation_id text;
CREATE UNIQUE INDEX IF NOT EXISTS purchases_account_row_identity
  ON public.purchases(account_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS purchases_one_replacement
  ON public.purchases(account_id,replaces_purchase_id)
  WHERE replaces_purchase_id IS NOT NULL;
DO $body$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid='public.purchases'::regclass AND conname='purchases_replacement_account_fk') THEN
    ALTER TABLE public.purchases ADD CONSTRAINT purchases_replacement_account_fk
      FOREIGN KEY(account_id,replaces_purchase_id) REFERENCES public.purchases(account_id,id)
      DEFERRABLE INITIALLY DEFERRED NOT VALID;
  END IF;
END $body$;

CREATE OR REPLACE FUNCTION public.tg_purchase_replacement_identity()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $body$
BEGIN
  IF OLD.replaces_purchase_id IS DISTINCT FROM NEW.replaces_purchase_id
    OR OLD.amendment_client_mutation_id IS DISTINCT FROM NEW.amendment_client_mutation_id THEN
    RAISE EXCEPTION 'purchase_amendment_link_immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $body$;
DROP TRIGGER IF EXISTS purchase_replacement_identity ON public.purchases;
CREATE TRIGGER purchase_replacement_identity BEFORE UPDATE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.tg_purchase_replacement_identity();

CREATE OR REPLACE FUNCTION public.tg_purchase_replacement_pair()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $body$
DECLARE child public.purchases; parent public.purchases;
BEGIN
  -- Check committed row state, including a later reversal in this transaction.
  SELECT * INTO child FROM public.purchases WHERE id=NEW.id;
  IF child.replaces_purchase_id IS NOT NULL THEN
    SELECT * INTO parent FROM public.purchases
      WHERE account_id=child.account_id AND id=child.replaces_purchase_id FOR SHARE;
    IF NOT FOUND OR parent.id=child.id OR parent.is_deleted IS DISTINCT FROM true
      OR child.amendment_client_mutation_id IS NULL
      OR parent.deletion_client_mutation_id IS DISTINCT FROM child.amendment_client_mutation_id THEN
      RAISE EXCEPTION 'purchase_amendment_pair_invalid' USING ERRCODE='23514';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.purchases p
    WHERE p.account_id=child.account_id AND p.replaces_purchase_id=child.id
      AND (child.is_deleted IS DISTINCT FROM true
        OR child.deletion_client_mutation_id IS DISTINCT FROM p.amendment_client_mutation_id)) THEN
    RAISE EXCEPTION 'purchase_amendment_pair_invalid' USING ERRCODE='23514';
  END IF;
  RETURN NULL;
END $body$;
REVOKE ALL ON FUNCTION public.tg_purchase_replacement_pair() FROM PUBLIC;
DROP TRIGGER IF EXISTS purchase_replacement_pair ON public.purchases;
CREATE CONSTRAINT TRIGGER purchase_replacement_pair AFTER INSERT OR UPDATE ON public.purchases
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.tg_purchase_replacement_pair();

-- Admin-only Hasura RPC. The caller is the Auth-validated clinic-sync handler;
-- permissions are also locked/rechecked here before any cached acknowledgement.
CREATE OR REPLACE FUNCTION public.amend_purchase_atomic(
  p_actor uuid,p_object jsonb,p_receipt jsonb,p_event jsonb
) RETURNS SETOF public.client_mutations LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public AS $body$
DECLARE
  account uuid := (p_object->>'account_id')::uuid;
  source_id uuid := (p_object->>'replaces_purchase_id')::uuid;
  mutation_id text := p_receipt->>'client_mutation_id';
  cached public.client_mutations;
  source public.purchases;
  replacement public.purchases;
  feature public.account_feature_permissions;
  super_actor boolean;
  receipt public.client_mutations;
  result jsonb;
  source_event_id uuid := gen_random_uuid();
BEGIN
  PERFORM 1 FROM auth.users WHERE id=p_actor AND disabled IS DISTINCT FROM true FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'purchase_amendment_denied' USING ERRCODE='42501'; END IF;
  PERFORM 1 FROM public.accounts WHERE id=account AND frozen IS DISTINCT FROM true FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'purchase_amendment_denied' USING ERRCODE='42501'; END IF;
  SELECT true INTO super_actor FROM public.super_admins
    WHERE user_uid=p_actor AND disabled IS DISTINCT FROM true FOR SHARE;
  IF super_actor IS DISTINCT FROM true THEN
    PERFORM 1 FROM public.account_users WHERE account_id=account AND user_uid=p_actor
      AND disabled IS DISTINCT FROM true FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchase_amendment_denied' USING ERRCODE='42501'; END IF;
    SELECT * INTO feature FROM public.account_feature_permissions
      WHERE account_id=account AND user_uid=p_actor FOR SHARE;
    IF NOT FOUND OR feature.can_update IS DISTINCT FROM true
      OR NOT (COALESCE(feature.allow_all,false) OR 'repository'=ANY(feature.allowed_features)) THEN
      RAISE EXCEPTION 'purchase_amendment_denied' USING ERRCODE='42501';
    END IF;
  END IF;
  IF source_id IS NULL OR mutation_id IS NULL OR btrim(mutation_id)=''
    OR COALESCE(p_object->>'device_id','')='' OR (p_object->>'local_id')::bigint <= 0
    OR (p_object->>'quantity')::integer <= 0 OR (p_object->>'total')::numeric < 0 THEN
    RAISE EXCEPTION 'purchase_amendment_payload_invalid' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(account::text||':'||mutation_id,0));
  SELECT * INTO cached FROM public.client_mutations
    WHERE account_id=account AND client_mutation_id=mutation_id FOR UPDATE;
  IF FOUND THEN
    IF cached.payload_hash IS DISTINCT FROM p_receipt->>'payload_hash' THEN
      RAISE EXCEPTION 'idempotency_payload_mismatch' USING ERRCODE='23514';
    END IF;
    RETURN NEXT cached; RETURN;
  END IF;
  SELECT * INTO source FROM public.purchases
    WHERE account_id=account AND id=source_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'purchase_amendment_source_missing' USING ERRCODE='23514'; END IF;
  IF source.is_deleted THEN
    RAISE EXCEPTION 'purchase_amendment_conflict' USING ERRCODE='23514';
  END IF;
  -- Credit first, then reverse: same-item net-positive amendments must not fail
  -- just because the original quantity has already been partially consumed.
  INSERT INTO public.purchases(id,account_id,device_id,local_id,item_id,quantity,total,date,
    created_at,updated_at,client_mutation_id,updated_by_user_id,replaces_purchase_id,amendment_client_mutation_id)
  VALUES ((p_object->>'id')::uuid,account,p_object->>'device_id',(p_object->>'local_id')::bigint,
    (p_object->>'item_id')::uuid,(p_object->>'quantity')::integer,(p_object->>'total')::double precision,
    (p_object->>'date')::timestamptz,COALESCE((p_object->>'created_at')::timestamptz,now()),
    now(),mutation_id,p_actor,source_id,mutation_id)
  RETURNING * INTO replacement;
  UPDATE public.purchases SET is_deleted=true,deleted_at=now(),deleted_by_user_id=p_actor,
    deletion_client_mutation_id=mutation_id,updated_by_user_id=p_actor,updated_at=now()
    WHERE id=source.id AND account_id=account RETURNING * INTO source;
  INSERT INTO public.sync_events(id,account_id,domain,entity_table,entity_id,operation_type,
    actor_user_id,client_mutation_id,correlation_id)
  VALUES ((p_event->>'id')::uuid,account,'inventory','purchases',replacement.id,'amend_purchase',
    p_actor,mutation_id,(p_event->>'correlation_id')::uuid),
    (source_event_id,account,'inventory','purchases',source.id,'reverse_purchase',
    p_actor,mutation_id||':reversal',(p_event->>'correlation_id')::uuid);
  result := jsonb_build_object('success',true,'operation','amend_purchase',
    'server_timestamp',replacement.updated_at,'data',jsonb_build_object(
      'entity_table','purchases','client_mutation_id',mutation_id,'remote_id',replacement.id,
      'server_version',replacement.server_version,'sync_event_id',(p_event->>'id')::uuid,
      'reversed_remote_id',source.id,'reversed_server_version',source.server_version,
      'reversal_sync_event_id',source_event_id));
  INSERT INTO public.client_mutations(id,account_id,client_mutation_id,operation_type,
    actor_user_id,payload_hash,correlation_id,result_json,completed_at)
  VALUES ((p_receipt->>'id')::uuid,account,mutation_id,'amend_purchase',p_actor,
    p_receipt->>'payload_hash',(p_event->>'correlation_id')::uuid,result,now())
  RETURNING * INTO receipt;
  RETURN NEXT receipt;
END $body$;
REVOKE ALL ON FUNCTION public.amend_purchase_atomic(uuid,jsonb,jsonb,jsonb) FROM PUBLIC;
COMMIT;
