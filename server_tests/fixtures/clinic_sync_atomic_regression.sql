\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE cases(label text PRIMARY KEY);
CREATE FUNCTION pg_temp.check_case(condition boolean, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
  INSERT INTO cases VALUES(label);
END $$;
INSERT INTO auth.users(id,disabled) VALUES('20000000-0000-4000-8000-000000000001',false);
INSERT INTO public.accounts(id,frozen) VALUES
  ('10000000-0000-4000-8000-000000000001',false),
  ('10000000-0000-4000-8000-000000000002',false);
INSERT INTO public.account_users(account_id,user_uid,disabled,role)
VALUES('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',false,'owner');
INSERT INTO public.account_feature_permissions(account_id,user_uid,allow_all,can_create,can_update,can_delete)
VALUES('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',true,true,true,true);
CREATE FUNCTION pg_temp.request(t text,op text,k bigint,cid text,v text,body jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb; object jsonb;
BEGIN
  object := jsonb_build_object('id',md5(t||':'||k::text)::uuid,
    'account_id','10000000-0000-4000-8000-000000000001',
    'device_id','fixture','local_id',k::text) || body;
  SELECT result_json INTO result FROM public.apply_clinic_sync_atomic(
    '20000000-0000-4000-8000-000000000001',t,op,v,object,
    jsonb_build_object('id',gen_random_uuid(),'client_mutation_id',cid,
      'payload_hash',repeat(md5(object::text||op||coalesce(v,'')),2)),
    jsonb_build_object('id',gen_random_uuid(),'correlation_id',gen_random_uuid()));
  RETURN result;
END $$;
CREATE FUNCTION pg_temp.expect_error(t text,op text,k bigint,cid text,v text,body jsonb,code text,label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text;
BEGIN
  BEGIN PERFORM pg_temp.request(t,op,k,cid,v,body);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS observed=MESSAGE_TEXT; END;
  PERFORM pg_temp.check_case(observed=code,label);
END $$;
DO $$
DECLARE result jsonb; replay jsonb; actual public.item_types; before_count bigint;
BEGIN
  result := pg_temp.request('item_types','create_item_type',1,'create-first','0','{"name":"first"}');
  SELECT * INTO actual FROM public.item_types WHERE local_id=1;
  PERFORM pg_temp.check_case(result->'data'->>'server_version'=actual.server_version::text
    AND result->'data'->>'server_version'='1','create returns actual version');
  PERFORM pg_temp.check_case((result->>'server_timestamp')::timestamptz=actual.updated_at,
    'timestamp comes from the persisted row');
  PERFORM pg_temp.check_case(result->'data'->'server_row'->>'local_id'='1'
    AND result->'data'->'server_row'->>'server_version'='1','origin and version are exact text');
  PERFORM pg_temp.check_case(NOT (result->'data'->'server_row' ? 'name')
    AND NOT (result->'data'->'server_row' ? 'diagnosis'),
    'shared retry receipts contain acknowledgement metadata without clinical data');
  replay := pg_temp.request('item_types','create_item_type',1,'create-first','0','{"name":"first"}');
  PERFORM pg_temp.check_case(replay=result,'lost response returns the identical receipt');
  PERFORM pg_temp.check_case((SELECT count(*) FROM public.sync_events
    WHERE account_id='10000000-0000-4000-8000-000000000001')=1
    AND (SELECT count(*) FROM public.client_mutations
    WHERE account_id='10000000-0000-4000-8000-000000000001')=1 AND actual.server_version=1,
    'replay creates no extra row event or version');
  PERFORM pg_temp.expect_error('item_types','create_item_type',1,'create-first','0',
    '{"name":"changed"}','idempotency_payload_mismatch','opaque CID rejects a different payload');
  result := pg_temp.request('item_types','update_item_type',1,'update-first','1','{"name":"second"}');
  PERFORM pg_temp.check_case(result->'data'->>'server_version'='2','CAS advances exactly once');
  PERFORM pg_temp.expect_error('item_types','update_item_type',1,'stale-update','1',
    '{"name":"stale"}','sync_version_conflict','stale update cannot overwrite the winner');
  PERFORM pg_temp.check_case((SELECT name FROM public.item_types WHERE local_id=1)='second'
    AND NOT EXISTS(SELECT FROM public.client_mutations WHERE client_mutation_id='stale-update'),
    'conflict leaves the row and receipt unchanged');
  PERFORM pg_temp.expect_error('item_types','update_item_type',1,'legacy-unknown',NULL,
    '{"name":"unknown baseline"}','sync_version_unknown','unknown legacy base is never invented');
  PERFORM pg_temp.expect_error('item_types','update_item_type',1,'malformed-version','01',
    '{"name":"invalid"}','sync_expected_version_invalid','noncanonical version fails before writing');
  result := pg_temp.request('item_types','delete_item_type',1,'delete-first','2','{"name":"forged on delete"}');
  PERFORM pg_temp.check_case(result->'data'->>'server_version'='3'
    AND (result->'data'->'server_row'->>'is_deleted')::boolean,
    'delete commits a versioned server-owned tombstone');
  PERFORM pg_temp.check_case((SELECT name FROM public.item_types WHERE local_id=1)='second',
    'delete privilege cannot rewrite business fields');
  PERFORM pg_temp.expect_error('item_types','update_item_type',1,'stale-delete-rival','2',
    '{"name":"revive"}','sync_version_conflict','delete-update race preserves the deletion');
  PERFORM pg_temp.expect_error('item_types','update_item_type',1,'revive-current','3',
    '{"name":"revive"}','sync_record_deleted','ordinary update cannot revive a deleted row');
END $$;

UPDATE auth.users SET disabled=true WHERE id='20000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect_error('item_types','create_item_type',1,'create-first','0',
  '{"name":"first"}','sync_atomic_denied','disabled actor cannot read a cached receipt');
UPDATE auth.users SET disabled=false WHERE id='20000000-0000-4000-8000-000000000001';
UPDATE public.accounts SET frozen=true WHERE id='10000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect_error('item_types','create_item_type',1,'create-first','0',
  '{"name":"first"}','sync_atomic_denied','frozen account cannot read a cached receipt');
UPDATE public.accounts SET frozen=false WHERE id='10000000-0000-4000-8000-000000000001';
UPDATE public.account_feature_permissions SET can_create=false;
SELECT pg_temp.expect_error('item_types','create_item_type',1,'create-first','0',
  '{"name":"first"}','sync_atomic_denied','CRUD revocation applies before receipt replay');
UPDATE public.account_feature_permissions SET can_create=true,allow_all=false,allowed_features=ARRAY[]::text[];
SELECT pg_temp.expect_error('item_types','create_item_type',2,'feature-denied','0',
  '{"name":"denied"}','sync_atomic_denied','feature denial blocks a fresh write');
UPDATE public.account_feature_permissions SET allow_all=true;
UPDATE public.account_users SET disabled=true;
SELECT pg_temp.expect_error('item_types','create_item_type',1,'create-first','0',
  '{"name":"first"}','sync_atomic_denied','membership revocation applies before receipt replay');
UPDATE public.account_users SET disabled=false;

INSERT INTO public.item_types(id,account_id,device_id,local_id,name)
VALUES('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','other',1,'foreign');
SELECT pg_temp.expect_error('item_types','create_item_type',2,'foreign-identity','0',
  '{"id":"30000000-0000-4000-8000-000000000001","name":"forged"}',
  'foreign_sync_identity','foreign UUID is rejected inside the transaction');
SELECT pg_temp.expect_error('item_types','create_item_type',2,'server-version-forged','0',
  '{"name":"forged","server_version":900}',
  'sync_atomic_request_invalid','client cannot assign a server version');

-- Apply the actual inventory stock triggers, not a mocked ledger calculation.
SELECT pg_temp.request('item_types','create_item_type',10,'type-ten','0','{"name":"inventory"}');
SELECT pg_temp.request('items','create_item',10,'item-ten','0',
  jsonb_build_object('name','item','type_id',md5('item_types:10')::uuid,'price',1,'price_minor','100'));
SELECT pg_temp.request('purchases','create_purchase',10,'purchase-ten','0',
  jsonb_build_object('item_id',md5('items:10')::uuid,'quantity',10,'total',10,
    'amount_minor','1000','unit_price_minor','100','date',now()));
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=10,'purchase credits stock once');
SELECT pg_temp.request('purchases','create_purchase',10,'purchase-ten','0',
  jsonb_build_object('item_id',md5('items:10')::uuid,'quantity',10,'total',10,
    'amount_minor','1000','unit_price_minor','100','date',now()));
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=10,'purchase response-loss retry does not duplicate stock');
SELECT pg_temp.request('purchases','update_purchase',10,'same-ledger-new-cid','1',
  jsonb_build_object('item_id',md5('items:10')::uuid,'quantity',10,'total',10,
    'amount_minor','1000','unit_price_minor','100','date',now()));
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=10,
  'new CID for an unchanged ledger does not duplicate stock');
SELECT pg_temp.expect_error('purchases','create_purchase',11,'money-mismatch','0',
  jsonb_build_object('item_id',md5('items:10')::uuid,'quantity',1,'total',1,
    'amount_minor','999','unit_price_minor','100','date',now()),
  'sync_money_mismatch','mismatched money rolls back its stock effect');
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=10
  AND NOT EXISTS(SELECT FROM public.purchases WHERE local_id=11)
  AND NOT EXISTS(SELECT FROM public.sync_events WHERE client_mutation_id='money-mismatch'),
  'money failure leaves no ledger row event receipt or stock change');

CREATE FUNCTION pg_temp.fail_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.client_mutation_id='fixture-fail-event' THEN
    RAISE EXCEPTION 'fixture_event_failure';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fixture_fail_event BEFORE INSERT ON public.sync_events
  FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_event();
SELECT pg_temp.expect_error('purchases','create_purchase',12,'fixture-fail-event','0',
  jsonb_build_object('item_id',md5('items:10')::uuid,'quantity',1,'total',1,
    'amount_minor','100','unit_price_minor','100','date',now()),
  'fixture_event_failure','event failure aborts the entire transaction');
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=10
  AND NOT EXISTS(SELECT FROM public.purchases WHERE local_id=12)
  AND NOT EXISTS(SELECT FROM public.client_mutations WHERE client_mutation_id='fixture-fail-event'),
  'event failure rolls back row stock and receipt');
SELECT pg_temp.request('purchases','reverse_purchase',10,'reverse-ledger','2','{}');
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=0,
  'reversal removes the original stock effect once');
SELECT pg_temp.request('purchases','reverse_purchase',10,'reverse-ledger','2','{}');
SELECT pg_temp.request('purchases','reverse_purchase',10,'reverse-ledger-new-cid','3','{}');
SELECT pg_temp.check_case((SELECT stock FROM public.items WHERE local_id=10)=0,
  'same and different CID reversals cannot debit stock twice');
DO $$
DECLARE object jsonb; legacy jsonb; replay jsonb;
BEGIN
  object := jsonb_build_object('id',md5('item_types:1')::uuid,
    'account_id','10000000-0000-4000-8000-000000000001',
    'device_id','fixture','local_id','1','name','second');
  legacy := jsonb_build_object('success',true,'operation','update_item_type',
    'server_timestamp','2026-10-11T00:00:00Z','data',jsonb_build_object(
      'entity_table','item_types','client_mutation_id','legacy-receipt',
      'remote_id',md5('item_types:1')::uuid,'server_version',NULL,
      'sync_event_id',gen_random_uuid()));
  INSERT INTO public.client_mutations(account_id,client_mutation_id,operation_type,
    actor_user_id,payload_hash,result_json)
  VALUES ('10000000-0000-4000-8000-000000000001','legacy-receipt','update_item_type',
    '20000000-0000-4000-8000-000000000001',
    repeat(md5(object::text||'update_item_type'),2),legacy);
  replay := pg_temp.request('item_types','update_item_type',1,'legacy-receipt',NULL,'{"name":"second"}');
  PERFORM pg_temp.check_case(replay=legacy,
    'legacy receipt replay keeps its original explicit unknown version');
END $$;
CREATE ROLE clinic_sync_test_unprivileged;
SELECT pg_temp.check_case(NOT has_function_privilege('clinic_sync_test_unprivileged',
  'public.apply_clinic_sync_atomic(uuid,text,text,text,jsonb,jsonb,jsonb)','EXECUTE'),
  'ordinary PUBLIC cannot execute the actor-selecting RPC');
SELECT label FROM cases ORDER BY label;
SELECT count(*) AS passed_native_cases FROM cases;
ROLLBACK;
