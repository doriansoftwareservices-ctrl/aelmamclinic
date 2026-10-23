'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {createNotificationFcmV2,resolveNotificationCredentials}=require('../functions/_shared/notification_fcm_v2');
const keys=crypto.generateKeyPairSync('rsa',{modulusLength:2048});
const credentials={clientEmail:'fixture@example.invalid',projectId:'fixture-project',
  privateKey:keys.privateKey.export({type:'pkcs8',format:'pem'})};
const name='projects/fixture-project/messages/0:123%abc';
const data=()=>({notification_protocol:'2',event_id:'nev2_'+'a'.repeat(64),target_id:crypto.randomUUID(),
  ack_nonce:crypto.randomUUID(),recipient_uid:crypto.randomUUID(),installation_id:crypto.randomUUID(),
  account_id:crypto.randomUUID(),kind:'new_patient',source_id:crypto.randomUUID()});
const response=(status,value)=>({status,text:async()=>JSON.stringify(value)});
function fixture({sendResponse=response(200,{name}),oauthResponse=response(200,{access_token:'synthetic-oauth',expires_in:3600}),...options}={}) {
  const calls=[];
  const send=createNotificationFcmV2({credentials,...options,fetchImpl:async(url,request)=>{
    calls.push({url,request});return url.includes('oauth2')?oauthResponse:sendResponse;
  }});
  return {calls,send:args=>send({token:'synthetic-device-token',data:data(),...args})};
}
test('real transport builds a verifiable scoped RSA OAuth assertion and data-only HTTP-v1 request',async()=>{
  const f=fixture();assert.deepEqual(await f.send(),{outcome:'accepted',providerMessageId:name});
  const assertion=new URLSearchParams(f.calls[0].request.body).get('assertion');const parts=assertion.split('.');
  assert.equal(crypto.verify('RSA-SHA256',Buffer.from(parts[0]+'.'+parts[1]),keys.publicKey,Buffer.from(parts[2],'base64url')),true);
  const claim=JSON.parse(Buffer.from(parts[1],'base64url'));assert.equal(claim.aud,'https://oauth2.googleapis.com/token');
  assert.equal(claim.scope,'https://www.googleapis.com/auth/firebase.messaging');assert.equal(claim.exp-claim.iat,3600);
  const payload=JSON.parse(f.calls[1].request.body);assert.equal(Object.hasOwn(payload.message,'notification'),false);
  assert.deepEqual(payload.message.android,{priority:'HIGH',ttl:'3600s'});
  assert.equal(f.calls[1].request.headers.Authorization,'Bearer synthetic-oauth');
});
test('cached credentials expire by monotonic duration rather than a backwards wall clock',async()=>{
  let wall=1000000,elapsed=100;const f=fixture({now:()=>wall,monotonicNow:()=>elapsed});
  await f.send();wall-=999999;elapsed+=1000;await f.send();assert.equal(f.calls.filter(c=>c.url.includes('oauth2')).length,1);
  elapsed+=3600000;await f.send();assert.equal(f.calls.filter(c=>c.url.includes('oauth2')).length,2);
});
for(const result of [{}, {name:''},{name:'projects/other-project/messages/id'},{name:'projects/fixture-project/messages/a/b'}]){
  test('unknown provider acceptance never completes a destination',async()=>{
    assert.deepEqual(await fixture({sendResponse:response(200,result)}).send(),{outcome:'retryable'});
  });
}
test('only typed Google UNREGISTERED returns a registration retirement result',async()=>{
  const f=fixture({sendResponse:response(404,{error:{details:[{'@type':'type.googleapis.com/google.firebase.fcm.v1.FcmError',errorCode:'UNREGISTERED'}]}})});
  assert.deepEqual(await f.send(),{outcome:'unregistered'});
});
for(const code of ['INVALID_ARGUMENT','SENDER_ID_MISMATCH','NOT_FOUND','QUOTA_EXCEEDED','UNREGISTERED']){
  test('untyped '+code+' cannot deactivate a device',async()=>{
    const f=fixture({sendResponse:response(400,{error:{status:code,message:'private registration token'}})});
    assert.deepEqual(await f.send(),{outcome:'retryable'});
  });
}
test('401 clears cached OAuth credentials for the next durable attempt',async()=>{
  const f=fixture({sendResponse:response(401,{error:{status:'UNAUTHENTICATED'}})});
  await f.send();await f.send();assert.equal(f.calls.filter(c=>c.url.includes('oauth2')).length,2);
});
test('missing OAuth credentials never enter the FCM call',async()=>{
  const f=fixture({oauthResponse:response(200,{expires_in:3600})});
  assert.deepEqual(await f.send(),{outcome:'retryable'});assert.equal(f.calls.length,1);
});
test('provider response body timeout aborts transport without exposing a token',async()=>{
  let signal;const send=createNotificationFcmV2({credentials,timeoutMs:10,fetchImpl:async(_url,request)=>{
    signal=request.signal;return {status:200,text:()=>new Promise(()=>{})};
  }});
  assert.deepEqual(await send({token:'private-token',data:data()}),{outcome:'retryable'});assert.equal(signal.aborted,true);
});
test('worker cancellation prevents a subsequent FCM send after late OAuth completion',async()=>{
  const controller=new AbortController();let calls=0;
  const send=createNotificationFcmV2({credentials,fetchImpl:async()=>{calls++;controller.abort();return response(200,{access_token:'x',expires_in:3600});}});
  assert.deepEqual(await send({token:'synthetic',data:data(),signal:controller.signal}),{outcome:'retryable'});assert.equal(calls,1);
});
test('invalid routing payload cannot enter OAuth or provider transport',async()=>{
  const f=fixture();assert.deepEqual(await f.send({data:{...data(),patient_name:'private'}}),{outcome:'retryable'});assert.equal(f.calls.length,0);
});
test('malformed explicit credential JSON cannot fall back to another project',()=>{
  assert.equal(resolveNotificationCredentials({FIREBASE_SERVICE_ACCOUNT_JSON:'invalid',FIREBASE_PROJECT_ID:'other-project'}),null);
  assert.throws(()=>createNotificationFcmV2({credentials:{...credentials,projectId:undefined}}),/notification_provider_not_configured/);
});
