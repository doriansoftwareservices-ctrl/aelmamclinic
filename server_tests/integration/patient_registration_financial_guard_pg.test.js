const test=require('node:test');const assert=require('node:assert/strict');const crypto=require('node:crypto');
const {openNotificationFixture}=require('./notification_fixture_bridge');
const enabled=process.env.ELMAM_NOTIFICATION_AUTHORITY_FIXTURE==='owned_pg14_20261023';
const owner='21000000-0000-4000-8000-000000000001',account='11000000-0000-4000-8000-000000009901';
// Only verified Auth identity is simulated. Every authority/identity/mutation
// query reaches the actual owned Hasura2.48.10 and PG14 fixture.
const shared=require.resolve('../../functions/_shared/storage_utils');const original=require.cache[shared];
require.cache[shared]={id:shared,filename:shared,loaded:true,exports:{readBody:async req=>req.body,extractBearer:()=> 'owned-verified-identity',resolveUserIdFromToken:async()=>owner}};
const handler=require('../../functions/clinic-sync');if(original)require.cache[shared]=original;else delete require.cache[shared];
let fixture,employee,doctor,salary,patient,device,cid,expected;
const sqlLiteral=value=>"'"+value.replaceAll("'","''")+"'";
test.before(async()=>{if(!enabled)return;fixture=openNotificationFixture();await fixture.query({document:'query FinancialGuardFixtureReady { __typename }'});});
test.beforeEach(async()=>{
 if(!enabled)return;expected=null;[employee,doctor,salary,patient]=Array.from({length:4},()=>crypto.randomUUID());device='financial-handler-'+patient;cid='financial-handler-'+crypto.randomUUID();
 await fixture.sql(`UPDATE public.notification_delivery_control_v2 SET capture_enabled=false,dispatch_enabled=false;
 INSERT INTO public.employees(id,account_id,device_id,local_id,name) VALUES('${employee}','${account}','${device}-e',1,'synthetic only');
 INSERT INTO public.doctors(id,account_id,device_id,local_id,name,employee_id) VALUES('${doctor}','${account}','${device}-d',1,'synthetic only','${employee}');
 INSERT INTO public.employees_salaries(id,account_id,device_id,local_id,employee_id,is_paid,payment_date,period_end) VALUES('${salary}','${account}','${device}-s',1,'${employee}',true,'2026-10-24T12:00:00Z','2026-10-24T12:00:00Z');
 INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,registered_at) VALUES('${patient}','${account}','${device}',1,'synthetic only','${doctor}','2026-10-24T11:00:00Z')`);
});
test.afterEach(async()=>{if(!enabled)return;await fixture.sql(`DELETE FROM public.sync_events WHERE account_id='${account}' AND client_mutation_id='${cid}';DELETE FROM public.client_mutations WHERE account_id='${account}' AND client_mutation_id='${cid}';DELETE FROM public.patients WHERE id='${patient}';DELETE FROM public.employees_salaries WHERE id='${salary}';DELETE FROM public.doctors WHERE id='${doctor}';DELETE FROM public.employees WHERE id='${employee}'`);});
test.after(async()=>{if(fixture)await fixture.close();});
async function image(){return JSON.parse(await fixture.sql(`SELECT json_build_object('patient',(SELECT to_jsonb(p) FROM public.patients p WHERE id='${patient}'),'salary',(SELECT to_jsonb(s) FROM public.employees_salaries s WHERE id='${salary}'),'receipts',(SELECT count(*) FROM public.client_mutations WHERE account_id='${account}' AND client_mutation_id='${cid}'),'events',(SELECT count(*) FROM public.sync_events WHERE account_id='${account}' AND client_mutation_id='${cid}'),'clock',(SELECT last_at FROM public.clinic_pull_clocks WHERE account_id='${account}'))`));}
async function invoke(fields){
 const before=await image();expected??=String(before.patient.server_version);const priorFetch=global.fetch;const priorAdmin=process.env.NHOST_ADMIN_SECRET;const priorUrl=process.env.NHOST_GRAPHQL_URL;
 process.env.NHOST_ADMIN_SECRET='elmam_fixture_admin_only';process.env.NHOST_GRAPHQL_URL='https://owned.graphql.fixture.nhost.run/v1';let mutations=0;
 global.fetch=async(url,options)=>{if(/^\s*mutation\b/.test(JSON.parse(options.body).query))mutations++;const result=await fixture.fetchImpl(url,options);return{status:result.status,ok:result.ok,text:async()=>JSON.stringify(await result.json())};};
 const res={statusCode:0,body:null,setHeader(){},status(value){this.statusCode=value;return this;},json(value){this.body=value;return this;}};
 try {await handler({method:'POST',body:{sync_protocol:2,operation_type:'update_patient',entity_table:'patients',account_id:account,device_id:device,local_id:'1',client_mutation_id:cid,expected_server_version:expected,payload:{id:patient,...fields,expected_server_version:expected}}},res);return{status:res.statusCode,body:res.body,mutations};}
 finally {global.fetch=priorFetch;if(priorAdmin===undefined)delete process.env.NHOST_ADMIN_SECRET;else process.env.NHOST_ADMIN_SECRET=priorAdmin;if(priorUrl===undefined)delete process.env.NHOST_GRAPHQL_URL;else process.env.NHOST_GRAPHQL_URL=priorUrl;}
}
test('actual sync RPC rolls back rejected paid edit and returns HTTP409 without a receipt',{skip:!enabled},async()=>{
 const before=await image();for(let attempt=0;attempt<2;attempt++){
  const res=await invoke({registered_at:'2026-10-24T13:00:00.123456Z'});
  assert.equal(res.status,409);assert.equal(res.body.error_code,'patient_registration_paid_period_locked');assert.equal(res.mutations,1);assert.deepEqual(await image(),before);
 }
});
test('actual sync cannot detach a paid visit by changing only its doctor',{skip:!enabled},async()=>{
 const before=await image();const res=await invoke({doctor_id:null});assert.equal(res.status,409);assert.equal(res.body.error_code,'patient_registration_paid_period_locked');assert.deepEqual(await image(),before);
});
test('actual canonical instant metadata edit preserves paid history and exact precision',{skip:!enabled},async()=>{
 const salaryBefore=(await image()).salary;const res=await invoke({registered_at:'2026-10-24T11:00:00.000000Z',notes:'metadata only'});
 assert.equal(res.status,200);const after=await image();assert.equal(after.patient.notes,'metadata only');assert.match(after.patient.registered_at,/2026-10-24T11:00:00/);assert.deepEqual(after.salary,salaryBefore);assert.equal(after.receipts,1);assert.equal(after.events,1);
});
test('a denied CID can commit after authorized coverage changes and then replays once',{skip:!enabled},async()=>{
 const fields={registered_at:'2026-10-24T13:00:00.123456Z'};assert.equal((await invoke(fields)).status,409);
 await fixture.sql(`UPDATE public.employees_salaries SET is_paid=false WHERE id='${salary}'`);
 const first=await invoke(fields);assert.equal(first.status,200);const committed=await image();assert.equal(committed.receipts,1);assert.equal(committed.events,1);assert.match(committed.patient.registered_at,/13:00:00.123456/);
 const replay=await invoke(fields);assert.equal(replay.status,200);assert.deepEqual(replay.body,first.body);assert.deepEqual(await image(),committed);
});

test('owned SQL bridge rolls back a failed batch and accepts its next request',{skip:!enabled},async()=>{
 const probe=crypto.randomUUID();const before=await image();
 await assert.rejects(fixture.sql(`UPDATE public.patients SET notes='must roll back' WHERE id='${patient}';SELECT 1/0`),/owned_fixture_SQL_failed/);
 assert.deepEqual(await image(),before);
 assert.equal(await fixture.sql('SELECT 42'),'42');
});
