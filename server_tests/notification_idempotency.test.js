'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createNotificationDispatchHandler}=require('../functions/_shared/notification_runtime_v2');
const env={NHOST_SUBDOMAIN:'fixture',NHOST_REGION:'fixture-region',NHOST_ADMIN_SECRET:'synthetic-admin',NHOST_WEBHOOK_SECRET:'synthetic-hook'};

test('repeated wakeups do not claim any destination while the durable queue is disabled',async()=>{
 let reads=0;
 const handler=createNotificationDispatchHandler({env,fetchImpl:async(_url,options)=>{
  reads++;const body=JSON.parse(options.body);
  assert.ok(body.query.includes('notification_delivery_control_v2'));
  return{ok:true,status:200,json:async()=>({data:{notification_delivery_control_v2:[{capture_enabled:false,dispatch_enabled:false}]}})};
 }});
 for(let n=0;n<3;n++){
  let result,status;
  await handler({method:'POST',headers:{'x-hasura-event-secret':'synthetic-hook'},body:{id:'same-old-webhook'}},
   {status(value){status=value;return this;},json(value){result=value;}});
  assert.equal(status,200);assert.equal(result.disabled,true);
 }
 assert.equal(reads,3);
});
test('v1 provider and premature-completion entry points are retired',()=>{
 const old=require('../functions/_shared/notify_utils');
 for(const name of ['sendFcm','claimNotificationEvent','markNotificationDispatchStarted','completeNotificationEvent'])assert.equal(old[name],undefined);
 assert.equal(typeof old.createNotificationDispatchHandler,'function');
});
