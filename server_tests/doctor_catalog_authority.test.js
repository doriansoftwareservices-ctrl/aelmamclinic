'use strict';
const assert=require('node:assert/strict');
const test=require('node:test');
const account='11111111-1111-4111-8111-111111111111';
const actor='22222222-2222-4222-8222-222222222222';
const remote='33333333-3333-4333-8333-333333333333';
const service='44444444-4444-4444-8444-444444444444';
const doctor='55555555-5555-4555-8555-555555555555';
const event='66666666-6666-4666-8666-666666666666';
const secondService='77777777-7777-4777-8777-777777777777';
const shared=require.resolve('../functions/_shared/storage_utils');
const prior=require.cache[shared];
require.cache[shared]={id:shared,filename:shared,loaded:true,exports:{
  readBody:async req=>req.body,extractBearer:()=> 'synthetic-fixture',resolveUserIdFromToken:async()=>actor,
}};
const handler=require('../functions/clinic-sync');
if(prior)require.cache[shared]=prior;else delete require.cache[shared];

async function attempt({table='medical_services',features=['employees'],type='doctorGeneral',
  priorType,existing=false,cached=false,legacy=false,memberDisabled=false,canCreate=true,
  canUpdate=true,oldServiceType='doctorGeneral',newServiceType='doctorGeneral',
  targetService=service,missingDoctor=false,foreignDoctor=false,payloadExtra={}}={}){
  const oldFetch=global.fetch,oldSecret=process.env.NHOST_ADMIN_SECRET;
  process.env.NHOST_ADMIN_SECRET='synthetic-server-only';
  const calls=[];let writes=0;
  const operation=`${existing?'update':'create'}_${table}`;
  const acknowledgement={success:true,operation,server_timestamp:'2026-10-19T00:00:00Z',data:{
    account_id:account,entity_table:table,client_mutation_id:'preserved-original-cid',
    remote_id:remote,server_version:'42',sync_event_id:event,
  }};
  const stored=existing?{id:remote,account_id:account,is_deleted:false,
    ...(table==='medical_services'?{service_type:priorType??type}:{service_id:service,doctor_id:doctor})}:null;
  global.fetch=async(_url,options)=>{
    const request=JSON.parse(options.body);calls.push(request);let data;
    if(request.query.includes('query SyncAccess'))data={
      account_users:[{role:'employee',disabled:memberDisabled}],accounts_by_pk:{id:account,frozen:false},
      super_admins:[],user:{disabled:false},account_feature_permissions:[{
        allow_all:false,allowed_features:features,can_create:canCreate,can_update:canUpdate,can_delete:true,
      }],
    };
    else if(request.query.includes('query DoctorServiceWriteScope'))data={rows:stored?[stored]:[],requested:stored?[stored]:[]};
    else if(request.query.includes('query DoctorServiceReferenceScope'))data={
      services:[{id:service,account_id:account,service_type:oldServiceType},
        ...(targetService!==service?[{id:targetService,account_id:account,service_type:newServiceType}]:[])],
      doctors:missingDoctor?[]:[{id:doctor,account_id:foreignDoctor?secondService:account}],
    };
    else if(request.query.includes('query ExistingMutation'))data={client_mutations:cached?[{
      id:event,operation_type:operation,result_json:acknowledgement,
    }]:[]};
    else if(request.query.includes('query ExistingSyncIdentity'))data={rows:stored?[stored]:[],requested:stored?[stored]:[]};
    else if(request.query.includes('mutation ClinicSyncApply')){writes++;data={rows:[{result_json:acknowledgement}]};}
    else throw new Error(`Unexpected fixture query: ${request.query.slice(0,80)}`);
    return{ok:true,text:async()=>JSON.stringify({data})};
  };
  const payload={id:remote,...(table==='medical_services'?{name:'Fixture service',...(type===undefined?{}:{service_type:type})}:
    {service_id:targetService,doctor_id:doctor,share_percentage:30,tower_share_percentage:70}),...payloadExtra};
  if(!legacy)payload.expected_server_version=existing?'7':'0';
  const response={statusCode:0,body:null,status(value){this.statusCode=value;return this;},json(value){this.body=value;return this;}};
  try{
    await handler({method:'POST',body:{operation_type:operation,entity_table:table,account_id:account,
      device_id:'fixture-device',local_id:'7',client_mutation_id:'preserved-original-cid',payload,
      sync_protocol:2,expected_server_version:legacy?null:(existing?'7':'0'),...(legacy?{legacy_prepared:true}:{}),
    }},response);
    return{status:response.statusCode,code:response.body?.error_code,writes,calls,body:response.body};
  }finally{global.fetch=oldFetch;if(oldSecret===undefined)delete process.env.NHOST_ADMIN_SECRET;else process.env.NHOST_ADMIN_SECRET=oldSecret;}
}
for(const type of['doctorGeneral','doctor','طبيب'])test(`employees authority creates ${type} service`,async()=>{
  const result=await attempt({type});assert.equal(result.status,200);assert.equal(result.writes,1);
});
test('employees authority manages a doctor service share through the actual parent',async()=>{
  const result=await attempt({table:'service_doctor_share'});assert.equal(result.status,200);assert.equal(result.writes,1);
});
test('lab authority keeps a laboratory service',async()=>{
  const result=await attempt({features:['lab_radiology'],type:'lab'});assert.equal(result.status,200);
});
test('lab authority cannot create a doctor service',async()=>{
  const result=await attempt({features:['lab_radiology']});assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('employees authority cannot create a laboratory service',async()=>{
  const result=await attempt({type:'lab'});assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('reception feature never authorizes catalog writes',async()=>{
  const result=await attempt({features:['patients.new','patients.list']});assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('changing doctor to laboratory requires old and new features',async()=>{
  const result=await attempt({features:['lab_radiology'],existing:true,priorType:'doctorGeneral',type:'lab'});
  assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('changing laboratory to doctor requires old and new features',async()=>{
  const result=await attempt({features:['employees'],existing:true,priorType:'lab',type:'doctorGeneral'});
  assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('both actual features permit an explicit service type change',async()=>{
  const result=await attempt({features:['employees','lab_radiology'],existing:true,priorType:'lab',type:'doctorGeneral'});
  assert.equal(result.status,200);
});
test('share classification cannot be forged through an unrelated payload service_type',async()=>{
  const result=await attempt({table:'service_doctor_share',oldServiceType:'lab',payloadExtra:{service_type:'doctorGeneral'}});
  assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('share moving from doctor to laboratory requires both parent features',async()=>{
  const result=await attempt({table:'service_doctor_share',existing:true,features:['lab_radiology'],
    targetService:secondService,newServiceType:'lab'});assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('share waits for a doctor that has not synchronized yet',async()=>{
  const result=await attempt({table:'service_doctor_share',missingDoctor:true});assert.equal(result.status,409);
  assert.equal(result.code,'mutation_dependency_pending');assert.equal(result.writes,0);
});
test('share cannot borrow a doctor identity from another clinic',async()=>{
  const result=await attempt({table:'service_doctor_share',foreignDoctor:true});assert.equal(result.status,403);
  assert.equal(result.code,'foreign_sync_reference');assert.equal(result.writes,0);
});
test('cached doctor receipt keeps current employees authority without lab permission',async()=>{
  const result=await attempt({existing:true,cached:true});assert.equal(result.status,200);
});
test('membership revocation denies a cached result before any receipt query',async()=>{
  const result=await attempt({existing:true,cached:true,memberDisabled:true});assert.equal(result.status,403);
  assert.equal(result.calls.some(call=>call.query.includes('ExistingMutation')),false);assert.equal(result.writes,0);
});
test('current laboratory scope denies a cached receipt to employees-only actor',async()=>{
  const result=await attempt({existing:true,cached:true,priorType:'lab',type:'lab'});
  assert.equal(result.status,403);assert.equal(result.writes,0);
});
test('CRUD revocation stays effective before dynamic feature lookup',async()=>{
  const result=await attempt({canCreate:false});assert.equal(result.status,403);
  assert.equal(result.calls.some(call=>call.query.includes('DoctorServiceWriteScope')),false);assert.equal(result.writes,0);
});
