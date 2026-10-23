'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {openNotificationFixture} = require('./notification_fixture_bridge');
const {resolveNotificationAuthority} = require('../../functions/_shared/notification_authority_v2');
const {dispatchNotificationBatchV2} = require('../../functions/_shared/notification_dispatch_v2');
const {createNotificationRepositoryV2} = require('../../functions/_shared/notification_repository_v2');
const enabled = process.env.ELMAM_NOTIFICATION_AUTHORITY_FIXTURE === 'owned_pg14_20261023';
const uid = '21000000-0000-4000-8000-000000000003';
const account = '11000000-0000-4000-8000-000000009901';
const doctor = '51000000-0000-4000-8000-000000000003';
const token = '61000000-0000-4000-8000-000000000003';
const additional = '61000000-0000-4000-8000-000000000023';
const accepted = {outcome: 'accepted', providerMessageId: 'projects/fixture/messages/known-v2-worker-acceptance'};
let fixture;let repository;let serial = 100;let patient;let sourceEvent;
test.before(() => {
  if (!enabled) return;
  fixture = openNotificationFixture();
  repository = createNotificationRepositoryV2({url: 'http://owned-fixture.invalid/v1/graphql',
    adminSecret: 'elmam_fixture_admin_only', fetchImpl: fixture.fetchImpl});
});
test.beforeEach(async () => {
  if (!enabled) return;
  patient = randomUUID();sourceEvent = null;
  await fixture.sql(`UPDATE public.notification_delivery_control_v2 SET capture_enabled=true,dispatch_enabled=false;
    INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,doctor_review_pending,registered_at)
    VALUES('${patient}','${account}','notification-worker-fixture',${++serial},'synthetic only','${doctor}',true,'2026-10-23T00:00:00.123456Z')`);
  const state = await rows();assert.equal(state.length, 1);sourceEvent = state[0].event_id;
});
test.afterEach(async () => {
  if (!enabled || !patient) return;
  await fixture.sql(`UPDATE public.notification_delivery_control_v2 SET capture_enabled=false,dispatch_enabled=false;
    UPDATE public.account_users SET disabled=false WHERE user_uid='${uid}' AND account_id='${account}';
    DELETE FROM public.notification_delivery_targets_v2 WHERE event_id IN (SELECT event_id FROM public.notification_delivery_events_v2 WHERE source_id='${patient}');
    DELETE FROM public.notification_delivery_events_v2 WHERE source_id='${patient}';
    DELETE FROM public.patients WHERE id='${patient}';
    DELETE FROM public.push_device_tokens WHERE id='${additional}';
    UPDATE public.push_device_tokens SET token='synthetic_authority_doc3',is_active=true WHERE id='${token}'`);
});
test.after(async () => {if (fixture) await fixture.close();});
async function rows() {
  return JSON.parse(await fixture.sql(`SELECT COALESCE(json_agg(to_jsonb(t) ORDER BY t.id),'[]'::json)::text
    FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id='${patient}'`));
}
const activate = () => fixture.sql('UPDATE public.notification_delivery_control_v2 SET dispatch_enabled=true');
function run(send = async () => accepted, overrides = {}) {
  return dispatchNotificationBatchV2({repository, resolveAuthority: target => resolveNotificationAuthority(target, {query: fixture.query}),
    send, ...overrides});
}
test('actual disabled barrier leaves the durable destination pending without a provider call', {skip: !enabled}, async () => {
  let sends = 0;const result = await run(async () => {sends++;return accepted;});
  assert.equal(result.disabled, true);assert.equal(sends, 0);
  const [target] = await rows();assert.equal(target.status, 'pending');assert.equal(target.attempts, 0);
});
test('actual worker records a known provider acceptance separately from a device ACK', {skip: !enabled}, async () => {
  await activate();const result = await run();assert.equal(result.recordedAccepted, 1);
  const [target] = await rows();assert.equal(target.status, 'accepted');
  assert.equal(target.provider_message_id, accepted.providerMessageId);assert.equal(target.acknowledged_at, null);
});
test('actual provider outage retries the same target after backoff without duplicating its event', {skip: !enabled}, async () => {
  await activate();assert.equal((await run(async () => {throw new Error('simulated provider unavailable');})).retryable, 1);
  const [first] = await rows();assert.equal(first.status, 'pending');assert.equal(first.provider_message_id, null);
  await fixture.sql(`UPDATE public.notification_delivery_targets_v2 SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE id='${first.id}'`);
  assert.equal((await run()).recordedAccepted, 1);
  const [second] = await rows();assert.equal(second.id, first.id);assert.equal(second.event_id, sourceEvent);
  assert.equal(second.ack_nonce, first.ack_nonce);assert.equal(second.attempts, 2);
});
test('actual partial outcome retries only the failed installation and preserves the accepted one', {skip: !enabled}, async () => {
  const oldPatient = patient;patient = randomUUID();
  await fixture.sql(`DELETE FROM public.notification_delivery_targets_v2 WHERE event_id IN (SELECT event_id FROM public.notification_delivery_events_v2 WHERE source_id='${oldPatient}');
    DELETE FROM public.notification_delivery_events_v2 WHERE source_id='${oldPatient}';DELETE FROM public.patients WHERE id='${oldPatient}';
    INSERT INTO public.push_device_tokens(id,user_uid,account_id,platform,token,installation_id,delivery_protocol)
    VALUES('${additional}','${uid}','${account}','android','synthetic_partial_device','${randomUUID()}',2);
    INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,registered_at)
    VALUES('${patient}','${account}','notification-worker-fixture',${++serial},'synthetic only','${doctor}','2026-10-23T00:00:00.123456Z')`);
  assert.equal((await rows()).length, 2);await activate();
  const first = await run(async request => request.token === 'synthetic_partial_device' ? {outcome: 'retryable'} : accepted);
  assert.equal(first.recordedAccepted, 1);assert.equal(first.retryable, 1);
  const state = await rows();const successful = state.find(row => row.status === 'accepted');
  const failed = state.find(row => row.status === 'pending');assert.ok(successful);assert.ok(failed);
  await fixture.sql(`UPDATE public.notification_delivery_targets_v2 SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE id='${failed.id}'`);
  let retries = 0;
  const second = await run(async request => {assert.equal(request.token, 'synthetic_partial_device');retries++;return accepted;});
  assert.equal(second.claimed, 1);assert.equal(retries, 1);
  assert.equal((await rows()).find(row => row.id === successful.id).attempts, 1);
  assert.equal((await rows()).find(row => row.id === failed.id).attempts, 2);
});
test('revoked membership cancels the actual destination without a provider call', {skip: !enabled}, async () => {
  await activate();await fixture.sql(`UPDATE public.account_users SET disabled=true WHERE user_uid='${uid}' AND account_id='${account}'`);
  let sends = 0;const result = await run(async () => {sends++;return accepted;});
  assert.equal(result.cancelled, 1);assert.equal(sends, 0);assert.equal((await rows())[0].status, 'cancelled');
});
test('revocation after the recipient read is still stopped by actual final SQL admission', {skip: !enabled}, async () => {
  await activate();let sends = 0;
  const result = await run(async () => {sends++;return accepted;}, {resolveAuthority: async target => {
    const authority = await resolveNotificationAuthority(target, {query: fixture.query});assert.equal(authority.allowed, true);
    await fixture.sql(`UPDATE public.account_users SET disabled=true WHERE user_uid='${uid}' AND account_id='${account}'`);
    return authority;
  }});
  assert.equal(sends, 0);assert.equal(result.fenced, 1);assert.equal((await rows())[0].status, 'processing');
});
test('actual send then lost persistence replays the same destination and nonce after lease recovery', {skip: !enabled}, async () => {
  await activate();const sent = [];
  const send = async args => {sent.push(args.data);return accepted;};
  const first = await run(send, {repository: {...repository, finish: async () => {throw new Error('simulated crash before DB persistence');}}});
  assert.equal(first.providerAccepted, 1);assert.equal(first.recordedAccepted, 0);assert.equal(first.unconfirmed, 1);
  const [target] = await rows();assert.equal(target.status, 'processing');assert.equal(target.provider_message_id, null);
  await fixture.sql(`UPDATE public.notification_delivery_targets_v2 SET lease_until=clock_timestamp()-interval '1 second' WHERE id='${target.id}'`);
  assert.equal((await run(send)).recordedAccepted, 1);
  assert.deepEqual(sent[0], sent[1]);assert.equal((await rows())[0].attempts, 2);
});
test('actual token rotation after authority read fences the old token before provider transport', {skip: !enabled}, async () => {
  await activate();let sends = 0;
  const first = await run(async () => {sends++;return accepted;}, {resolveAuthority: async target => {
    const authority = await resolveNotificationAuthority(target, {query: fixture.query});
    await fixture.sql(`UPDATE public.push_device_tokens SET token='synthetic_dispatch_rotation' WHERE id='${token}'`);
    return authority;
  }});
  assert.equal(first.fenced, 1);assert.equal(sends, 0);
  const [target] = await rows();await fixture.sql(`UPDATE public.notification_delivery_targets_v2 SET lease_until=clock_timestamp()-interval '1 second' WHERE id='${target.id}'`);
  assert.equal((await run(async request => {assert.equal(request.token, 'synthetic_dispatch_rotation');return accepted;})).recordedAccepted, 1);
  assert.equal((await rows())[0].id, target.id);
});
test('actual provider acceptance without a message ID remains pending for recovery', {skip: !enabled}, async () => {
  await activate();assert.equal((await run(async () => ({outcome: 'accepted'}))).retryable, 1);
  const [target] = await rows();assert.equal(target.status, 'pending');assert.equal(target.provider_accepted_at, null);
});
test('simulated device ACK through actual SQL can win the race before provider-result persistence', {skip: !enabled}, async () => {
  await activate();
  const result = await run(async request => {
    const data = await fixture.query({document: `mutation FixtureAck($id: uuid!, $uid: uuid!, $nonce: uuid!) {
      acknowledge_notification_target_v2(args:{p_id:$id,p_actor:$uid,p_nonce:$nonce}){id status}
    }`, variables: {id: request.data.target_id, uid, nonce: request.data.ack_nonce}});
    assert.equal(data.acknowledge_notification_target_v2[0].status, 'acknowledged');return accepted;
  });
  assert.equal(result.fenced, 1);assert.equal(result.recordedAccepted, 0);
  const [target] = await rows();assert.equal(target.status, 'acknowledged');
  assert.equal(target.provider_message_id, null);assert.ok(target.acknowledged_at);
});
test('actual invalid old-token cleanup cannot deactivate a token rotated during provider send', {skip: !enabled}, async () => {
  await activate();
  const first = await run(async () => {
    await fixture.sql(`UPDATE public.push_device_tokens SET token='synthetic_rotated_during_send' WHERE id='${token}'`);
    return {outcome: 'unregistered'};
  });
  assert.equal(first.retryable, 1);
  const registration = JSON.parse(await fixture.sql(`SELECT json_build_object('token',token,'active',is_active)::text FROM public.push_device_tokens WHERE id='${token}'`));
  assert.deepEqual(registration, {token: 'synthetic_rotated_during_send', active: true});
  const [target] = await rows();await fixture.sql(`UPDATE public.notification_delivery_targets_v2 SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE id='${target.id}'`);
  assert.equal((await run(async request => {assert.equal(request.token, registration.token);return accepted;})).recordedAccepted, 1);
});
test('actual unknown application roles cannot read queue controls or execute private delivery RPCs', {skip: !enabled}, async () => {
  for (const role of ['user','me','owner','employee','support','superadmin']) {
    for (const document of ['query {notification_delivery_control_v2 {dispatch_enabled}}',
      'mutation {claim_notification_targets_v2(args:{p_worker:"'+uid+'",p_limit:1}){id}}',
      'mutation {admit_notification_target_v2(args:{p_id:"'+uid+'",p_lease:"'+uid+'",p_registration:"'+token+'",p_token:"synthetic"}){id}}']) {
      await assert.rejects(fixture.query({document, actor: {uid, role}}), /owned_fixture_graphql_unavailable/);
    }
  }
});
