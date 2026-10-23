'use strict';
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs');
const path=require('node:path');
const test=require('node:test');
const base=new URL(process.env.ELMAM_DOCTOR_CATALOG_HASURA_URL);
assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');assert.ok(Number(base.port)>1024);
const admin=process.env.ELMAM_DOCTOR_CATALOG_ADMIN,key=process.env.ELMAM_DOCTOR_CATALOG_JWT;
assert.ok(admin?.length>=32);assert.ok(key?.length>=32);
const metadataPath=process.env.ELMAM_DOCTOR_CATALOG_METADATA;
const uuid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function token(actor,roles=['user','me']){
  const header=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
  const payload=Buffer.from(JSON.stringify({sub:uuid(actor),iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+600,
    'https://hasura.io/jwt/claims':{'x-hasura-user-id':uuid(actor),'x-hasura-default-role':'user','x-hasura-allowed-roles':roles}})).toString('base64url');
  return`${header}.${payload}.${crypto.createHmac('sha256',key).update(`${header}.${payload}`).digest('base64url')}`;
}
async function post(route,body,headers){
  assert.ok(['/v1/graphql','/v1/metadata','/v2/query'].includes(route));
  const response=await fetch(new URL(route,base),{method:'POST',redirect:'error',headers:{'content-type':'application/json',...headers},
    body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
  return{status:response.status,body:await response.json()};
}
async function gql(query,actor=14,{jwt,role='user',roles,headers={},variables={}}={}){
  return post('/v1/graphql',{query,variables},{authorization:`Bearer ${jwt||token(actor,roles)}`,'x-hasura-role':role,...headers});
}
async function sql(statement){
  const result=await post('/v2/query',{type:'run_sql',args:{source:'default',sql:statement,read_only:false}}, {'x-hasura-admin-secret':admin});
  assert.equal(result.status,200,`Synthetic SQL failed: ${result.body.error||result.status}`);return result.body;
}
function catalogQuery(account=1){return`query{
  doctors(where:{account_id:{_eq:"${uuid(account)}"}},order_by:{id:asc}){id name specialization phone_number start_time end_time}
  medical_services(where:{account_id:{_eq:"${uuid(account)}"}},order_by:{id:asc}){id name service_type cost cost_minor is_deleted}
  service_doctor_share(where:{account_id:{_eq:"${uuid(account)}"}},order_by:{id:asc}){id service_id doctor_id share_percentage tower_share_percentage is_hidden is_deleted}
  employees(where:{account_id:{_eq:"${uuid(account)}"}}){id basic_salary final_salary}
  employees_salaries(where:{account_id:{_eq:"${uuid(account)}"}}){id net_pay}
  financial_logs(where:{account_id:{_eq:"${uuid(account)}"}}){id amount}
}`;}
async function catalog(actor=14,options){
  const result=await gql(catalogQuery(options?.account||1),actor,options);
  assert.equal(result.status,200);assert.equal(result.body.errors,undefined,result.body.errors?.map(error=>error.message).join('; '));
  return result.body.data;
}
function noRows(data){for(const[name,rows]of Object.entries(data))assert.deepEqual(rows,[],name);}
let nonce=200;
function intent({table='medical_services',kind='doctorGeneral',payload={}}={}){
  const n=++nonce,operation=`create_${table}`;
  const object={id:uuid(1000+n),account_id:uuid(1),device_id:'second-device-fixture',local_id:String(n),
    ...(table==='medical_services'?{name:`Published fixture ${n}`,service_type:kind,cost:'234.56',cost_minor:'23456'}:
      {service_id:uuid(41),doctor_id:uuid(31),share_percentage:'25',tower_share_percentage:'75'}),...payload};
  return{table,operation,object,cid:`real-hasura-doctor-${n}`,hash:crypto.createHash('sha256').update(JSON.stringify(object)).digest('hex')};
}
async function rpc(request,actor=11){
  return post('/v1/graphql',{query:`mutation CatalogWrite($actor:uuid!,$table:String!,$operation:String!,$object:jsonb!,$receipt:jsonb!,$event:jsonb!){
    apply_clinic_sync_atomic(args:{p_actor:$actor,p_table:$table,p_operation:$operation,p_expected_version:"0",p_object:$object,p_receipt:$receipt,p_event:$event}){result_json}}`,variables:{
      actor:uuid(actor),table:request.table,operation:request.operation,object:request.object,
      receipt:{id:crypto.randomUUID(),client_mutation_id:request.cid,payload_hash:request.hash},
      event:{id:crypto.randomUUID(),correlation_id:crypto.randomUUID()},
    }},{'x-hasura-admin-secret':admin});
}
function rpcSuccess(result){
  assert.equal(result.status,200);assert.equal(result.body.errors,undefined,result.body.errors?.map(error=>error.message).join('; '));
  const receipt=result.body.data.apply_clinic_sync_atomic[0].result_json;assert.equal(receipt.success,true);return receipt;
}

test.before(async()=>{
  const metadata=JSON.parse(fs.readFileSync(metadataPath,'utf8'));
  const result=await post('/v1/metadata',{type:'replace_metadata',args:{allow_inconsistent_metadata:false,metadata}}, {'x-hasura-admin-secret':admin});
  fs.writeFileSync(path.join(path.dirname(metadataPath),'doctor_catalog_metadata_apply_result.json'),JSON.stringify(result,null,2));
  assert.equal(result.status,200,`Real Hasura metadata application failed: ${result.body.error||'unknown'}`);
  const consistency=await post('/v1/metadata',{type:'get_inconsistent_metadata',args:{}},{'x-hasura-admin-secret':admin});
  assert.equal(consistency.body.is_consistent,true);
  const marker=await sql('SELECT value FROM public.elmam_doctor_catalog_fixture_marker;');
  assert.equal(marker.result[1][0],'local_doctor_catalog_20261019');
  // Nonempty controls make financial isolation assertions meaningful.
  await sql(`INSERT INTO public.employees(id,account_id,device_id,local_id,name,basic_salary,final_salary)
    VALUES('${uuid(101)}','${uuid(1)}','staff-fixture',1,'Synthetic employee','10000','10000');
    INSERT INTO public.employees_salaries(id,account_id,device_id,local_id,employee_id,net_pay)
    VALUES('${uuid(102)}','${uuid(1)}','staff-fixture',1,'${uuid(101)}','10000');
    INSERT INTO public.financial_logs(id,account_id,device_id,local_id,amount)
    VALUES('${uuid(103)}','${uuid(1)}','staff-fixture',1,'10000');`);
});

for(const role of['user','me'])test(`reception ${role} sees doctor aliases, shares and selectors`,async()=>{
  const data=await catalog(14,{role});
  assert.deepEqual(data.doctors.map(row=>row.id),[uuid(31)]);
  assert.deepEqual(data.medical_services.map(row=>row.id),[uuid(41),uuid(42),uuid(43)]);
  assert.deepEqual(data.service_doctor_share.map(row=>row.id),[uuid(61)]);
  assert.equal(data.service_doctor_share[0].share_percentage,'25');
  assert.equal(data.service_doctor_share[0].tower_share_percentage,'75');
});
test('reception doctor catalog does not expose laboratory or radiology services',async()=>{
  const data=await catalog();assert.ok(!data.medical_services.some(row=>['lab','radiology'].includes(row.service_type)));
});
test('reception denies legacy share borrowing a foreign service parent',async()=>{
  assert.ok(!(await catalog()).service_doctor_share.some(row=>row.id===uuid(64)));
});
test('reception denies legacy share borrowing a foreign doctor parent',async()=>{
  assert.ok(!(await catalog()).service_doctor_share.some(row=>row.id===uuid(65)));
});
test('reception does not gain employee salaries or financial logs',async()=>{
  const data=await catalog();assert.deepEqual(data.employees,[]);assert.deepEqual(data.employees_salaries,[]);assert.deepEqual(data.financial_logs,[]);
  assert.ok((await catalog(11)).employees.length>0);
});
test('patients.new alone permits read-only doctor catalog',async()=>{
  await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.new']::text[] WHERE user_uid='${uuid(14)}';`);
  try{assert.ok((await catalog()).medical_services.length>0);}
  finally{await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.new','patients.list']::text[] WHERE user_uid='${uuid(14)}';`);}
});
test('patients.list alone permits read-only doctor catalog',async()=>{
  await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.list']::text[] WHERE user_uid='${uuid(14)}';`);
  try{assert.ok((await catalog()).medical_services.length>0);}
  finally{await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.new','patients.list']::text[] WHERE user_uid='${uuid(14)}';`);}
});
test('employees-only manager now receives doctor services and shares',async()=>{
  const data=await catalog(11);assert.ok(data.medical_services.some(row=>row.id===uuid(41)));assert.ok(data.service_doctor_share.some(row=>row.id===uuid(61)));
  assert.ok(!data.medical_services.some(row=>row.id===uuid(44)));
});
test('existing laboratory catalog access stays available',async()=>{
  assert.ok((await catalog(13)).medical_services.some(row=>row.id===uuid(44)));
});
test('foreign clinic catalog stays invisible to reception',async()=>noRows(await catalog(14,{account:2})));
test('request user-id header cannot borrow foreign membership',async()=>{
  noRows(await catalog(14,{account:2,headers:{'x-hasura-user-id':uuid(16)}}));
});
test('forbidden superadmin role header is rejected by the real JWT engine',async()=>{
  const result=await gql(catalogQuery(),14,{role:'superadmin'});assert.ok(result.status===400||result.status===401||result.body.errors?.length>0);
});
test('a forged allowed superadmin claim cannot replace the DB registry',async()=>noRows(await catalog(14,{role:'superadmin',roles:['user','superadmin']})));
for(const[label,change,restore]of[
  ['feature revocation',`UPDATE public.account_feature_permissions SET allowed_features=ARRAY[]::text[] WHERE user_uid='${uuid(14)}'`,
    `UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.new','patients.list']::text[] WHERE user_uid='${uuid(14)}'`],
  ['membership revocation',`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(14)}'`,
    `UPDATE public.account_users SET disabled=false WHERE user_uid='${uuid(14)}'`],
  ['Auth disabled',`UPDATE auth.users SET disabled=true WHERE id='${uuid(14)}'`,
    `UPDATE auth.users SET disabled=false WHERE id='${uuid(14)}'`],
  ['clinic freeze',`UPDATE public.accounts SET frozen=true WHERE id='${uuid(1)}'`,
    `UPDATE public.accounts SET frozen=false WHERE id='${uuid(1)}'`],
])test(`same reception JWT loses all reads after ${label}`,async()=>{
  const jwt=token(14);assert.ok((await catalog(14,{jwt})).medical_services.length>0);
  await sql(change);try{noRows(await catalog(14,{jwt}));}finally{await sql(restore);}
});
test('same existing JWT sees the catalog immediately after a fresh feature grant',async()=>{
  const jwt=token(19);await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY[]::text[] WHERE user_uid='${uuid(19)}';`);
  try{noRows(await catalog(19,{jwt}));
    await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.new']::text[] WHERE user_uid='${uuid(19)}';`);
    assert.ok((await catalog(19,{jwt})).medical_services.length>0);
  }finally{await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['employees']::text[] WHERE user_uid='${uuid(19)}';`);}
});
for(const table of['doctors','medical_services','service_doctor_share'])test(`reception has no direct ${table} GraphQL write grant`,async()=>{
  const result=await gql(`mutation{delete_${table}(where:{account_id:{_eq:"${uuid(1)}"}}){affected_rows}}`);
  assert.ok(result.body.errors?.length>0);
});
test('ordinary JWT cannot choose an actor for the private atomic RPC',async()=>{
  const result=await gql('mutation{apply_clinic_sync_atomic(args:{p_actor:"'+uuid(11)+'",p_table:"medical_services",p_operation:"create",p_expected_version:"0",p_object:{},p_receipt:{},p_event:{}}){result_json}}');
  assert.ok(result.body.errors?.length>0);
});
test('doctor tombstones stay readable for deterministic sync removal',async()=>{
  await sql(`UPDATE public.medical_services SET is_deleted=true WHERE id='${uuid(43)}';`);
  try{assert.equal((await catalog()).medical_services.find(row=>row.id===uuid(43)).is_deleted,true);}
  finally{await sql(`UPDATE public.medical_services SET is_deleted=false WHERE id='${uuid(43)}';`);}
});
test('service and share written with employees authority reach a second JWT and reception',async()=>{
  const service=intent();const first=rpcSuccess(await rpc(service));
  const share=intent({table:'service_doctor_share',payload:{service_id:service.object.id}});rpcSuccess(await rpc(share));
  assert.equal(first.data.server_version,'1');
  for(const actor of[12,14]){
    const received=await catalog(actor);assert.ok(received.medical_services.some(row=>row.id===service.object.id));
    assert.ok(received.service_doctor_share.some(row=>row.id===share.object.id));
  }
  assert.deepEqual(rpcSuccess(await rpc(service)),first);
});
test('actual atomic RPC denies reception even though it can read the catalog',async()=>{
  const response=await rpc(intent(),14);assert.ok(response.body.errors?.length>0);
});
test('actual atomic RPC rechecks current feature before a cached receipt',async()=>{
  const request=intent();rpcSuccess(await rpc(request));
  await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY[]::text[] WHERE user_uid='${uuid(11)}';`);
  try{assert.ok((await rpc(request)).body.errors?.length>0);}
  finally{await sql(`UPDATE public.account_feature_permissions SET allowed_features=ARRAY['employees']::text[] WHERE user_uid='${uuid(11)}';`);}
});
