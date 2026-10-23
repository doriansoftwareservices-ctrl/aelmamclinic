'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {createNotificationRegistrationHandler,createNotificationReceiptHandler}=require('../functions/_shared/notification_device_v2');
const uid='21000000-0000-4000-8000-000000000003',account='11000000-0000-4000-8000-000000009901';
const install='81000000-0000-4000-8000-000000000003',target='91000000-0000-4000-8000-000000000003';
const source='31000000-0000-4000-8000-000000009901',doctor='51000000-0000-4000-8000-000000000003';
const token='61000000-0000-4000-8000-000000000003',nonce='71000000-0000-4000-8000-000000000003';
const secret=Buffer.alloc(32,7).toString('base64url'),secretHash=crypto.createHash('sha256').update(secret).digest('hex');
const env={NHOST_SUBDOMAIN:'fixture',NHOST_REGION:'fixture-region',NHOST_ADMIN_SECRET:'synthetic-admin'};
function fixture(change=()=>{}) {
  const state={binding:{secret_hash:secretHash,bound_user_uid:uid,is_active:true},
    target:{id:target,event_id:'nev2_'+'a'.repeat(64),user_uid:uid,token_id:token,installation_id:install,ack_nonce:nonce,status:'accepted',
      delivery_event:{event_id:'nev2_'+'a'.repeat(64),event_type:'new_patient',source_id:source,account_id:account}},
    identity:{user:{id:uid,disabled:false},super_admins:[],push_device_tokens:[{id:token,user_uid:uid,account_id:account,
      is_active:true,platform:'android',token:'private-transport-token',locale_code:'ar',installation_id:install,delivery_protocol:2}]},
    patient:{patients:[{id:source,account_id:account,doctor_id:doctor}]},doctor:{doctors:[{id:doctor,account_id:account,user_uid:uid}]},
    acknowledged_at:'2026-10-23T00:00:00.123456+00:00',registrationError:null};
  change(state);const calls=[];let authCalls=0;
  const fetchImpl=async(url,request)=>{
    if(url.includes('.auth.')){authCalls++;return{status:200,json:async()=>({id:uid,disabled:false})};}
    const body=JSON.parse(request.body);calls.push(body);let data;
    if(body.query.includes('mutation RegisterNotificationInstallation')) {
      if(state.registrationError)return{status:200,json:async()=>({errors:[state.publicErrorOnly?{message:state.registrationError,extensions:{code:'permission-error'}}:{extensions:{internal:{error:{message:state.registrationError}}}}]})};
      data={register_notification_installation_v2:[{installation_id:install,client_revision:body.variables.revision,bound_user_uid:uid,is_active:!body.variables.deactivate}]};
    } else if(body.query.includes('query NotificationInstallationProof'))data={notification_installations_v2_by_pk:state.binding};
    else if(body.query.includes('query NotificationDestinationProof'))data={notification_delivery_targets_v2_by_pk:state.target};
    else if(body.query.includes('query NotificationRecipientInstallation'))data=state.identity;
    else if(body.query.includes('query NotificationPatient'))data=state.patient;
    else if(body.query.includes('query NotificationAssignedDoctor'))data=state.doctor;
    else if(body.query.includes('mutation AcknowledgeNotificationDestination'))data={acknowledge_notification_target_v2:[{id:target,status:'acknowledged',acknowledged_at:state.acknowledged_at}]};
    else throw new Error('unexpected_fixture_document');
    return{status:200,ok:true,json:async()=>({data})};
  };
  async function invoke(kind,body,headers={authorization:'Bearer synthetic-verified-by-Auth'}) {
    let status,result;const factory=kind==='register'?createNotificationRegistrationHandler:createNotificationReceiptHandler;
    await factory({env,fetchImpl})({method:'POST',headers,body},
      {status(code){status=code;return this;},json(value){result=value;}});
    return{status,body:result};
  }
  return{calls,state,invoke,get authCalls(){return authCalls;},register:extra=>invoke('register',{installation_id:install,installation_secret:secret,revision:'1',account_id:account,token:'synthetic-token',locale:'ar',...extra}),
    receipt:extra=>invoke('receipt',{installation_id:install,installation_secret:secret,target_id:target,ack_nonce:nonce,...extra})};
}
test('registration derives its actor from Auth and exposes no installation proof or provider token',async()=>{
  const f=fixture();const result=await f.register();assert.deepEqual(result,{status:200,body:{ok:true,notification_protocol:2,revision:'1',active:true}});
  assert.equal(f.calls[0].variables.uid,uid);assert.equal(f.calls[0].variables.proof,secretHash);
  assert.ok(!JSON.stringify(result).includes(secret));
});
test('same registration replay produces the exact same private request identity',async()=>{
  const f=fixture();await f.register();await f.register();assert.deepEqual(f.calls[0].variables,f.calls[1].variables);
});
test('client-supplied UID or role cannot enter privileged registration',async()=>{
  const f=fixture();assert.equal((await f.register({uid:crypto.randomUUID()})).status,400);assert.equal(f.calls.length,0);
});
for(const revision of ['0','01','-1','1.5','9007199254740992',1.1,null]){
  test('invalid revision cannot rebind an installation',async()=>{
    const f=fixture();assert.equal((await f.register({revision})).status,400);assert.equal(f.calls.length,0);
  });
}
test('logout sends a revisioned deactivation without depending on a remaining FCM token',async()=>{
  const f=fixture();assert.equal((await f.register({deactivate:true,token:null})).body.active,false);assert.equal(f.calls[0].variables.token,null);
});
for(const [code,status] of [['notification_registration_stale',409],['notification_installation_secret_mismatch',403],['notification_registration_denied',403]]){
  test('typed registration '+code+' stays explicit without leaking SQL',async()=>{
    const f=fixture(s=>{s.registrationError=code;});assert.deepEqual(await f.register(),{status,body:{ok:false,error:code}});
  });
}
test('ordinary upstream details are sanitized rather than returned to the client',async()=>{
  const f=fixture(s=>{s.registrationError='private-patient-and-token';});
  assert.deepEqual(await f.register(),{status:503,body:{ok:false,error:'notification_temporarily_unavailable'}});
});
test('receipt requires the physical installation proof before reading a destination',async()=>{
  const f=fixture(s=>{s.binding.secret_hash='b'.repeat(64);});assert.equal((await f.receipt()).status,403);assert.equal(f.calls.length,1);
});
test('a rebound installation cannot acknowledge its previous actor destination',async()=>{
  const f=fixture(s=>{s.binding.bound_user_uid=crypto.randomUUID();});assert.equal((await f.receipt()).status,403);assert.equal(f.calls.length,1);
});
test('wrong nonce or another installation cannot acknowledge a destination',async()=>{
  const f=fixture();assert.equal((await f.receipt({ack_nonce:crypto.randomUUID()})).status,404);
  assert.ok(!f.calls.some(c=>c.query.startsWith('mutation')));
});
test('current source authority is checked before issuing a device ACK',async()=>{
  const f=fixture(s=>{s.patient.patients=[];});assert.equal((await f.receipt()).status,403);assert.ok(!f.calls.some(c=>c.query.startsWith('mutation')));
});
test('validated receipt contains only its device acknowledgement and known server time',async()=>{
  const f=fixture();const result=await f.receipt();assert.deepEqual(result,{status:200,body:{ok:true,acknowledged:true,acknowledged_at:f.state.acknowledged_at}});
  assert.ok(!JSON.stringify(result).includes('private-transport-token'));
});
test('tap validation returns scoped routing and does not manufacture a receipt',async()=>{
  const f=fixture();assert.deepEqual(await f.receipt({action:'validate'}),{status:200,body:{ok:true,authorized:true,kind:'new_patient',account_id:account,source_id:source}});
  assert.ok(!f.calls.some(c=>c.query.startsWith('mutation')));
});
test('malformed server ACK time remains unavailable rather than inventing the current time',async()=>{
  const f=fixture(s=>{s.acknowledged_at='unknown';});assert.equal((await f.receipt()).status,503);
});
test('background capability validates and acknowledges without refreshing or requiring Auth',async()=>{
  const f=fixture();const body={installation_id:install,installation_secret:secret,target_id:target,ack_nonce:nonce};
  assert.equal((await f.invoke('receipt',{...body,action:'validate'},{})).status,200);
  assert.equal((await f.invoke('receipt',body,{})).status,200);assert.equal(f.authCalls,0);
});
test('a bare device capability cannot bypass a disabled recipient',async()=>{
  const f=fixture(s=>{s.identity.user.disabled=true;});
  assert.equal((await f.invoke('receipt',{installation_id:install,installation_secret:secret,target_id:target,ack_nonce:nonce},{})).status,403);
  assert.ok(!f.calls.some(c=>c.query.startsWith('mutation')));assert.equal(f.authCalls,0);
});
test('registration requires verified Auth independently of the device capability',async()=>{
  const f=fixture();
  assert.equal((await f.invoke('register',{installation_id:install,installation_secret:secret,revision:'1',token:'synthetic'},{})).status,401);
  assert.equal(f.calls.length,0);
});
for(const code of ['notification_registration_stale','notification_registration_identity_mismatch']) {
  test('actual Hasura public check prefix retains typed '+code,async()=>{
    const f=fixture(s=>{s.registrationError='Check constraint violation. '+code;s.publicErrorOnly=true;});
    assert.deepEqual(await f.register(),{status:409,body:{ok:false,error:code}});
  });
}
