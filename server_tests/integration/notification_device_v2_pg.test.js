'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {openNotificationFixture}=require('./notification_fixture_bridge');
const {createNotificationRegistrationHandler,createNotificationReceiptHandler}=require('../../functions/_shared/notification_device_v2');
const enabled=process.env.ELMAM_NOTIFICATION_AUTHORITY_FIXTURE==='owned_pg14_20261023';
const uid='21000000-0000-4000-8000-000000000003',other='21000000-0000-4000-8000-000000000002';
const account='11000000-0000-4000-8000-000000009901',doctor='51000000-0000-4000-8000-000000000003';
const env={NHOST_GRAPHQL_URL:'https://owned.graphql.fixture.invalid/v1',NHOST_AUTH_URL:'https://owned.auth.fixture.invalid/v1',NHOST_ADMIN_SECRET:'elmam_fixture_admin_only'};
let fixture,install,secret,patient,target,authCalls,registerHandler,receiptHandler;
test.before(async()=>{
  if(!enabled)return;
  fixture=openNotificationFixture();
  // Start the owned Docker transport before exercising the product's fixed
  // four-second upstream deadline; bridge startup is not a Hasura response.
  await fixture.query({document:'query NotificationFixtureReady { __typename }',variables:{}});
});
test.beforeEach(async()=>{
  if(!enabled)return;
  install=crypto.randomUUID();secret=crypto.randomBytes(32).toString('base64url');patient=null;target=null;authCalls=0;
  const fetchImpl=async(url,options)=>{
    if(url.includes('.auth.')){authCalls++;const actor=options.headers.Authorization?.replace('Bearer ','');
      return{status:actor===uid||actor===other?200:401,json:async()=>({id:actor,disabled:false})};}
    return fixture.fetchImpl(url,options);
  };
  registerHandler=createNotificationRegistrationHandler({env,fetchImpl});receiptHandler=createNotificationReceiptHandler({env,fetchImpl});
  await fixture.sql('UPDATE public.notification_delivery_control_v2 SET capture_enabled=false,dispatch_enabled=false');
});
test.afterEach(async()=>{
  if(!enabled)return;
  await fixture.sql(`UPDATE public.notification_delivery_control_v2 SET capture_enabled=false,dispatch_enabled=false;
    UPDATE auth.users SET disabled=false WHERE id='${uid}';
    UPDATE public.account_users SET disabled=false WHERE user_uid='${uid}' AND account_id='${account}';
    DELETE FROM public.notification_delivery_targets_v2 WHERE event_id IN (SELECT event_id FROM public.notification_delivery_events_v2 WHERE source_id='${patient||'00000000-0000-0000-0000-000000000000'}');
    DELETE FROM public.notification_delivery_events_v2 WHERE source_id='${patient||'00000000-0000-0000-0000-000000000000'}';
    DELETE FROM public.patients WHERE id='${patient||'00000000-0000-0000-0000-000000000000'}';
    DELETE FROM public.push_device_tokens WHERE installation_id='${install}';
    DELETE FROM public.notification_installations_v2 WHERE installation_id='${install}'`);
});
test.after(async()=>{if(fixture)await fixture.close();});
async function invoke(handler,body,bearer=null){
  let status,result;
  await handler({method:'POST',headers:bearer?{authorization:'Bearer '+bearer}:{},body},
    {status(value){status=value;return this;},json(value){result=value;}});
  return{status,body:result};
}
function registration(extra={},actor=uid){return invoke(registerHandler,{installation_id:install,installation_secret:secret,
  revision:'1',account_id:account,token:'device-fixture-'+install,locale:'ar',...extra},actor);}
function receipt(extra={},actor=null){return invoke(receiptHandler,{installation_id:install,installation_secret:secret,
  target_id:target.id,ack_nonce:target.ack_nonce,...extra},actor);}
async function binding(){return JSON.parse(await fixture.sql(`SELECT row_to_json(i) FROM public.notification_installations_v2 i WHERE installation_id='${install}'`));}
async function destination(){
  assert.equal((await registration()).status,200);patient=crypto.randomUUID();
  await fixture.sql(`UPDATE public.notification_delivery_control_v2 SET capture_enabled=true,dispatch_enabled=true;
    INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,registered_at)
    VALUES('${patient}','${account}','device-handler-fixture-${install}',1,'synthetic only','${doctor}','2026-10-23T00:00:00.123456Z');
    SELECT count(*) FROM public.claim_notification_targets_v2(gen_random_uuid(),20)`);
  target=JSON.parse(await fixture.sql(`SELECT row_to_json(t) FROM public.notification_delivery_targets_v2 t
    JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id='${patient}' AND t.installation_id='${install}'`));
  await fixture.sql(`SELECT public.finish_notification_target_v2('${target.id}','${target.lease_token}','accepted',NULL,'projects/fixture/messages/known-device-handler')`);
}
test('actual registration stores protocol2 and derives its actor only from verified Auth',{skip:!enabled},async()=>{
  assert.equal((await registration()).status,200);const row=await binding();assert.equal(row.bound_user_uid,uid);assert.equal(row.client_revision,1);
  const state=JSON.parse(await fixture.sql(`SELECT row_to_json(t) FROM public.push_device_tokens t WHERE installation_id='${install}' AND is_active`));
  assert.equal(state.delivery_protocol,2);assert.equal(state.locale_code,'ar');assert.equal(state.role,null);
});
test('actual lost registration response replays the same row and server instant',{skip:!enabled},async()=>{
  await registration();const first=await binding();assert.equal((await registration()).status,200);assert.deepEqual(await binding(),first);
});
test('actual SQL proof mismatch and stale revisions retain typed public errors',{skip:!enabled},async()=>{
  await registration({revision:'2'});
  assert.equal((await registration()).status,409);
  assert.equal((await registration({revision:'3',installation_secret:crypto.randomBytes(32).toString('base64url')})).status,403);
  assert.equal((await binding()).client_revision,2);
});
test('actual Auth-disabled and membership-disabled actors cannot bind devices',{skip:!enabled},async()=>{
  await fixture.sql(`UPDATE auth.users SET disabled=true WHERE id='${uid}'`);
  assert.equal((await registration()).status,403);
  await fixture.sql(`UPDATE auth.users SET disabled=false WHERE id='${uid}';UPDATE public.account_users SET disabled=true WHERE user_uid='${uid}' AND account_id='${account}'`);
  assert.equal((await registration()).status,403);
});
test('actual token rotation retains one installation and one current active token',{skip:!enabled},async()=>{
  await registration();assert.equal((await registration({revision:'2',token:'device-fixture-rotated-'+install})).status,200);
  assert.equal(await fixture.sql(`SELECT count(*) FROM public.push_device_tokens WHERE installation_id='${install}' AND is_active`),'1');
});
test('actual background capability validates routing without Auth rotation or premature ACK',{skip:!enabled},async()=>{
  await destination();authCalls=0;assert.deepEqual(await receipt({action:'validate'}),{status:200,body:{ok:true,authorized:true,kind:'new_patient',account_id:account,source_id:patient}});
  assert.equal(authCalls,0);assert.equal(await fixture.sql(`SELECT status FROM public.notification_delivery_targets_v2 WHERE id='${target.id}'`),'accepted');
});
test('actual device ACK uses a known SQL instant and remains idempotent',{skip:!enabled},async()=>{
  await destination();const first=await receipt();assert.equal(first.status,200);assert.ok(first.body.acknowledged_at);
  assert.deepEqual(await receipt(),first);assert.equal(await fixture.sql(`SELECT status FROM public.notification_delivery_targets_v2 WHERE id='${target.id}'`),'acknowledged');
});
test('actual wrong nonce cannot validate or acknowledge another destination',{skip:!enabled},async()=>{
  await destination();assert.equal((await receipt({ack_nonce:crypto.randomUUID()})).status,404);
  assert.equal(await fixture.sql(`SELECT status FROM public.notification_delivery_targets_v2 WHERE id='${target.id}'`),'accepted');
});
test('actual source reassignment revokes a captured notification before display',{skip:!enabled},async()=>{
  await destination();await fixture.sql(`UPDATE public.patients SET doctor_id=NULL WHERE id='${patient}'`);
  assert.equal((await receipt({action:'validate'})).status,403);assert.equal((await receipt()).status,403);
});
test('actual actor replacement makes the former actor target unavailable',{skip:!enabled},async()=>{
  await destination();assert.equal((await registration({revision:'2'},other)).status,200);
  assert.equal((await receipt({action:'validate'})).status,404);
  assert.equal((await receipt({},uid)).status,403);
});
test('actual logout retires the device capability before any later receipt',{skip:!enabled},async()=>{
  await destination();assert.equal((await registration({revision:'2',deactivate:true,token:null})).status,200);
  assert.equal((await receipt()).status,403);
});
test('ordinary Hasura roles cannot read installation secrets or call the private registration RPC',{skip:!enabled},async()=>{
  await registration();
  await assert.rejects(fixture.query({document:'query { notification_installations_v2 { secret_hash } }',variables:{},actor:{role:'user',uid}}));
  await assert.rejects(fixture.query({document:'mutation { register_notification_installation_v2(args:{}) { installation_id } }',variables:{},actor:{role:'user',uid}}));
  assert.equal((await binding()).client_revision,1);
});
test('ordinary direct GraphQL token edits cannot bypass installation revision proof',{skip:!enabled},async()=>{
  await registration();
  await assert.rejects(fixture.query({document:'mutation($install:uuid!){update_push_device_tokens(where:{installation_id:{_eq:$install}},_set:{is_active:false}){affected_rows}}',variables:{install},actor:{role:'user',uid}}));
  assert.equal(await fixture.sql(`SELECT count(*) FROM public.push_device_tokens WHERE installation_id='${install}' AND is_active`),'1');
});
