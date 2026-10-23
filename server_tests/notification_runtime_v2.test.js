'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createNotificationDispatchHandler,notificationConfig,notificationBody,notificationActor}=require('../functions/_shared/notification_runtime_v2');
const env={NHOST_SUBDOMAIN:'fixture',NHOST_REGION:'fixture-region',NHOST_ADMIN_SECRET:'synthetic-admin',NHOST_WEBHOOK_SECRET:'synthetic-hook'};
async function invoke(options={},req={}) {
  let status,body;const handler=createNotificationDispatchHandler({env,...options});
  await handler({method:'POST',headers:{'x-hasura-event-secret':'synthetic-hook'},...req},{status(code){status=code;return this;},json(value){body=value;}});
  return {status,body};
}
test('disabled server queue requires no provider credentials and sends nothing',async()=>{
  let calls=0;const result=await invoke({fetchImpl:async()=>{calls++;return{status:200,ok:true,json:async()=>({data:{notification_delivery_control_v2:[{capture_enabled:false,dispatch_enabled:false}]}})};}});
  assert.equal(result.status,200);assert.equal(result.body.disabled,true);assert.equal(calls,1);
});
test('missing provider credentials do not claim or exhaust durable destinations',async()=>{
  let calls=0;const result=await invoke({fetchImpl:async()=>{calls++;return{status:200,ok:true,json:async()=>({data:{notification_delivery_control_v2:[{capture_enabled:true,dispatch_enabled:true}]}})};}});
  assert.equal(result.status,503);assert.equal(calls,1);
});
for(const [headers,expected] of [[{},401],[{'x-hasura-event-secret':'invalid'},403]]){
  test('invalid dispatcher secret does not reach privileged GraphQL',async()=>{
    let calls=0;const result=await invoke({fetchImpl:async()=>{calls++;throw new Error();}},{headers});assert.equal(result.status,expected);assert.equal(calls,0);
  });
}
test('unsupported methods perform no privileged or provider work',async()=>{
  const result=await invoke({fetchImpl:async()=>{throw new Error();}},{method:'GET'});assert.equal(result.status,405);
});
test('server errors expose no upstream credential or patient fields',async()=>{
  const result=await invoke({fetchImpl:async()=>{throw new Error('private-token-and-patient');}});
  assert.deepEqual(result,{status:503,body:{ok:false,error:'notification_temporarily_unavailable'}});
});
test('Auth URL normalization does not append a second v1 or reuse the GraphQL route',()=>{
  const config=notificationConfig({...env,NHOST_GRAPHQL_URL:'https://fixture.graphql.region.nhost.run/v1/graphql'});
  assert.equal(config.auth,'https://fixture.auth.region.nhost.run/v1/user');
  assert.equal(config.graphql,'https://fixture.graphql.region.nhost.run/v1/graphql');
});
test('request body is bounded before dispatching privileged operations',async()=>{
  await assert.rejects(notificationBody({body:{x:'x'.repeat(8192)}}),error=>error.status===413);
  await assert.rejects(notificationBody({body:[]}),error=>error.status===400);
});
test('Auth actor comes from the verified Auth response, not request fields or JWT text',async()=>{
  const uid='21000000-0000-4000-8000-000000000001';
  const actor=await notificationActor({headers:{authorization:'Bearer synthetic-unparsed-token'},body:{uid:'foreign'}},notificationConfig(env),async()=>({status:200,json:async()=>({id:uid,disabled:false})}));
  assert.equal(actor,uid);
});
test('Auth denial remains401 while Auth transport failure remains retryable503',async()=>{
  const req={headers:{authorization:'Bearer synthetic'}};const config=notificationConfig(env);
  await assert.rejects(notificationActor(req,config,async()=>({status:401,json:async()=>({})})),error=>error.status===401);
  await assert.rejects(notificationActor(req,config,async()=>{throw new Error('private');}),error=>error.status===503);
});
