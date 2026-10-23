'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
process.env.NHOST_GRAPHQL_URL='https://fixture.graphql.region.nhost.run/v1';
process.env.NHOST_AUTH_URL='https://fixture.auth.region.nhost.run/v1';
process.env.GRAPHQL_ADMIN_SECRET='synthetic-admin';
process.env.NHOST_WEBHOOK_SECRET='synthetic-hook';
process.env.HASURA_EVENT_SECRET='synthetic-hook';
const originalFetch=globalThis.fetch;
const calls=[];
// The real entry point captures its transport when the module is initialized.
// Install the owned transport first; never weaken the product dependency scope.
globalThis.fetch=async(_url,options)=>{
 const body=JSON.parse(options.body);calls.push(body);
 return{status:200,ok:true,json:async()=>({data:{notification_delivery_control_v2:[{capture_enabled:false,dispatch_enabled:false}]}})};
};
test.after(()=>{globalThis.fetch=originalFetch;});
const dispatch=require('../functions/notify-dispatch-v2');
for(const route of ['notify-new-patient','notify-chat-message','notify-plan-request']){
 const handler=require('../functions/'+route);
 async function invoke(headers={},body={}){
  let status,result;
  await handler({method:'POST',headers,body},{status(value){status=value;return this;},json(value){result=value;}});
  return{status,result};
 }
 test(route+' invokes the same guarded durable dispatcher',()=>assert.equal(handler,dispatch));
 test(route+' rejects a caller without a webhook secret before privileged work',async()=>{
  assert.equal((await invoke()).status,401);
 });
 test(route+' rejects a wrong secret before privileged work',async()=>{
  assert.equal((await invoke({'x-hasura-event-secret':'wrong'})).status,403);
 });
 test(route+' treats webhook source/recipients as an untrusted wakeup payload',async()=>{
  calls.length=0;
  const reply=await invoke({'x-hasura-event-secret':'synthetic-hook'},
   {event:{data:{new:{id:'untrusted-source',user_uid:'forged-recipient',role:'superadmin'}}},tokens:['forged-token']});
  assert.equal(reply.status,200);assert.equal(reply.result.disabled,true);assert.equal(calls.length,1);
  assert.ok(!JSON.stringify(calls).includes('forged-recipient'));
  assert.ok(!JSON.stringify(calls).includes('forged-token'));
 });
}
