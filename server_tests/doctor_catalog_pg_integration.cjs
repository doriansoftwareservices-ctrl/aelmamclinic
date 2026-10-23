'use strict';
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const test=require('node:test');
assert.equal(process.env.PGHOST,'127.0.0.1');assert.equal(process.env.PGHOSTADDR,'127.0.0.1');
assert.equal(process.env.PGUSER,'elmam_doctor_catalog_fixture');
assert.match(process.env.PGDATABASE||'',/^elmam_doctor_catalog_fixture_[a-z0-9_]+$/);
assert.match(process.env.ELMAM_DOCTOR_CATALOG_PSQL||'',/PostgreSQL[\\/]18\.6[\\/]bin[\\/]psql\.exe$/i);
const uuid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const account=uuid(1);
let serial=100;
const literal=value=>`'${JSON.stringify(value).replaceAll("'","''")}'::jsonb`;
function execute(sql){return execFileSync(process.env.ELMAM_DOCTOR_CATALOG_PSQL,
  ['-X','-q','-A','-t','-v','ON_ERROR_STOP=1'],{input:sql,encoding:'utf8',timeout:10000,
    env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=5000'},stdio:['pipe','pipe','pipe']});}
function query(sql){return JSON.parse(execute(`SELECT coalesce(json_agg(row_to_json(r)),'[]'::json)::text FROM (${sql})r;`).trim());}
function intent({actor=11,table='medical_services',kind='doctorGeneral',payload={},id,local,device='catalog-writer',expected='0',op}={}){
  const n=++serial;
  const object={id:id||uuid(1000+n),account_id:account,device_id:device,local_id:String(local||n),
    ...(table==='medical_services'?{name:`Fixture ${n}`,service_type:kind,cost:'123.45',cost_minor:'12345'}:
      {service_id:uuid(41),doctor_id:uuid(31),share_percentage:'25',tower_share_percentage:'75'}),...payload};
  const operation=op||`${expected==='0'?'create':'update'}_${table}`;
  return{actor,table,operation,expected,object,cid:`catalog-intent-${n}`,
    hash:crypto.createHash('sha256').update(JSON.stringify({object,operation,expected})).digest('hex')};
}
function apply(request,{actor=request.actor,sparse=false}={}){
  const object=sparse?Object.fromEntries(Object.entries(request.object).filter(([key])=>['id','account_id','device_id','local_id'].includes(key))):request.object;
  return query(`SELECT result_json FROM public.apply_clinic_sync_atomic('${uuid(actor)}','${request.table}',
    '${request.operation}',${request.expected===null?'NULL':`'${request.expected}'`},${literal(object)},
    ${literal({id:crypto.randomUUID(),client_mutation_id:request.cid,payload_hash:request.hash})},
    ${literal({id:crypto.randomUUID(),correlation_id:crypto.randomUUID()})})`)[0].result_json;
}
function reject(request,message,options){
  let error;try{apply(request,options);}catch(value){error=value;}
  assert.ok(error,`Expected ${message}`);assert.ok(String(error.stderr).includes(message),String(error.stderr));
}
function noReceipt(request){
  assert.equal(query(`SELECT count(*)::integer AS n FROM public.client_mutations WHERE client_mutation_id='${request.cid}'`)[0].n,0);
  assert.equal(query(`SELECT count(*)::integer AS n FROM public.sync_events WHERE client_mutation_id='${request.cid}'`)[0].n,0);
}
assert.equal(query('SELECT value FROM public.elmam_doctor_catalog_fixture_marker')[0].value,'local_doctor_catalog_20261019');
for(const kind of['doctorGeneral','doctor','طبيب'])test(`real SQL employees creates ${kind} with exact canonical cost`,()=>{
  const request=intent({kind});const result=apply(request);
  assert.equal(result.success,true);assert.equal(result.data.server_version,'1');
  const row=query(`SELECT cost_minor::text,server_version FROM public.medical_services WHERE id='${request.object.id}'`)[0];
  assert.deepEqual(row,{cost_minor:'12345',server_version:1});
});
test('real SQL employees creates an actual doctor-service share',()=>{
  const result=apply(intent({table:'service_doctor_share'}));assert.equal(result.success,true);
});
test('real SQL lab authority keeps laboratory write access',()=>{
  assert.equal(apply(intent({actor:13,kind:'lab'})).success,true);
});
for(const[label,request]of[
  ['reception has no write authority',()=>intent({actor:14})],
  ['employees cannot create lab',()=>intent({kind:'lab'})],
  ['lab cannot create doctor',()=>intent({actor:13})],
  ['disabled identity',()=>intent({actor:17})],
  ['foreign clinic actor',()=>intent({actor:16})],
])test(`real SQL denies ${label} without row/event/receipt`,()=>{
  const value=request();reject(value,'sync_atomic_denied');noReceipt(value);
});
test('changing a stored doctor service to lab requires both real features',()=>{
  const request=intent({kind:'lab',id:uuid(41),device:'seed',local:41,expected:'1'});
  reject(request,'sync_atomic_denied');noReceipt(request);
});
test('changing stored lab to doctor cannot use only employees authority',()=>{
  const request=intent({id:uuid(44),device:'seed',local:44,expected:'1'});
  reject(request,'sync_atomic_denied');noReceipt(request);
});
test('both features permit an explicit CAS classification change',()=>{
  const created=intent({actor:15});apply(created);
  const change=intent({actor:15,kind:'lab',id:created.object.id,local:created.object.local_id,expected:'1'});
  assert.equal(apply(change).data.server_version,'2');
  const stale=intent({actor:15,kind:'lab',id:created.object.id,local:created.object.local_id,expected:'1'});
  reject(stale,'sync_version_conflict');noReceipt(stale);
});
test('an existing share cannot move to a lab parent with employees authority',()=>{
  const request=intent({table:'service_doctor_share',id:uuid(61),device:'seed',local:61,expected:'1',payload:{service_id:uuid(44)}});
  reject(request,'sync_atomic_denied');noReceipt(request);
});
test('a share cannot borrow a foreign service parent',()=>{
  const request=intent({table:'service_doctor_share',payload:{service_id:uuid(46)}});
  reject(request,'foreign_sync_reference');noReceipt(request);
});
test('a share cannot borrow a foreign doctor parent',()=>{
  const request=intent({table:'service_doctor_share',payload:{doctor_id:uuid(32)}});
  reject(request,'foreign_sync_reference');noReceipt(request);
});
test('a not-yet-synchronized parent remains a retryable dependency',()=>{
  const request=intent({table:'service_doctor_share',payload:{service_id:uuid(999)}});
  reject(request,'sync_catalog_dependency_pending');noReceipt(request);
});
test('unchanged retry preserves the original receipt, CID and version',()=>{
  const request=intent();const first=apply(request);const replay=apply(request);
  assert.deepEqual(replay,first);
  assert.equal(query(`SELECT count(*)::integer AS n FROM public.sync_events WHERE client_mutation_id='${request.cid}'`)[0].n,1);
});
test('a sparse prepared retry rechecks the actual stored doctor classification',()=>{
  const request=intent();const first=apply(request);
  assert.deepEqual(apply(request,{sparse:true}),first);
});
test('current feature revocation denies a cached receipt',()=>{
  const request=intent();apply(request);
  execute(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY[]::text[] WHERE user_uid='${uuid(11)}';`);
  try{reject(request,'sync_atomic_denied');}
  finally{execute(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['employees']::text[] WHERE user_uid='${uuid(11)}';`);}
});
test('membership revocation denies a sparse cached receipt',()=>{
  const request=intent();apply(request);execute(`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(11)}';`);
  try{reject(request,'sync_atomic_denied',{sparse:true});}
  finally{execute(`UPDATE public.account_users SET disabled=false WHERE user_uid='${uuid(11)}';`);}
});
test('freeze denies existing receipts including active superadmin',()=>{
  const request=intent({actor:21});apply(request);execute(`UPDATE public.accounts SET frozen=true WHERE id='${account}';`);
  try{reject(request,'sync_atomic_denied');}finally{execute(`UPDATE public.accounts SET frozen=false WHERE id='${account}';`);}
});
test('delete authority does not rewrite service type or money',()=>{
  const created=intent();apply(created);
  const deletion=intent({id:created.object.id,local:created.object.local_id,expected:'1',kind:'lab',
    op:'delete_medical_service',payload:{cost_minor:'999999'}});
  apply(deletion);
  const row=query(`SELECT service_type,cost_minor::text,is_deleted FROM public.medical_services WHERE id='${created.object.id}'`)[0];
  assert.deepEqual(row,{service_type:'doctorGeneral',cost_minor:'12345',is_deleted:true});
});
test('private classifier and atomic actor selection are not executable by SQL client',()=>{
  for(const sql of[
    `SELECT public.doctor_service_sync_features('medical_services','${account}',NULL,'{}'::jsonb,false)`,
    `SELECT * FROM public.apply_clinic_sync_atomic('${uuid(11)}','medical_services','create','0','{}','{}','{}')`,
  ])assert.throws(()=>execute(`BEGIN;SET LOCAL ROLE elmam_doctor_catalog_client;${sql};ROLLBACK;`),
    error=>String(error.stderr).includes('permission denied for function'));
});
