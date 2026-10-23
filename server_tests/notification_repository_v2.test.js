'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {documents, createNotificationRepositoryV2} = require('../functions/_shared/notification_repository_v2');
const {NotificationDispatchUnavailable} = require('../functions/_shared/notification_dispatch_v2');

function fixture() {
  const target = {id: randomUUID(), event_id: 'nev2_' + 'c'.repeat(64), user_uid: randomUUID(),
    installation_id: randomUUID(), lease_token: randomUUID()};
  const state = {
    enabled: {notification_delivery_control_v2: [{capture_enabled: true, dispatch_enabled: true}]},
    claim: {claim_notification_targets_v2: [target]},
    admit: {admit_notification_target_v2: [{...target, status: 'processing'}]},
    finish: {finish_notification_target_v2: [{...target, status: 'accepted', provider_message_id: 'projects/fixture/messages/id'}]},
    deactivate: {deactivate_notification_registration_v2: [{id: target.id, user_uid: target.user_uid,
      installation_id: target.installation_id, is_active: false}]},
  };
  const calls = [];
  const repository = createNotificationRepositoryV2({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-admin-only', fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      const name = Object.keys(documents).find(key => documents[key] === request.query);
      assert.ok(name);calls.push({name, request, options});
      return {ok: true, json: async () => ({data: structuredClone(state[name])})};
    }});
  const args = {target, registrationId: target.id, token: 'synthetic-token'};
  return {repository, target, state, calls, args};
}
test('typed claim keeps private actor headers immutable and the requested batch bounded', async () => {
  const f = fixture();assert.equal(await f.repository.enabled(), true);
  assert.deepEqual(await f.repository.claim({worker: f.target.id, limit: 8}), [f.target]);
  assert.equal(f.calls[1].request.variables.limit, 8);
  assert.ok(f.calls.every(c => Object.isFrozen(c.options.headers)));
  assert.ok(f.calls.every(c => !Object.hasOwn(c.options.headers, 'x-hasura-role')));
});
test('admission binds the exact currently resolved registration and transport token', async () => {
  const f = fixture();assert.equal(await f.repository.admit(f.args), true);
  assert.deepEqual(f.calls[0].request.variables, {id: f.target.id, lease: f.target.lease_token,
    registration: f.target.id, token: 'synthetic-token'});
});
test('empty typed admission and outcome are fences rather than success', async () => {
  const f = fixture();f.state.admit.admit_notification_target_v2 = [];
  f.state.finish.finish_notification_target_v2 = [];
  assert.equal(await f.repository.admit(f.args), false);
  assert.equal(await f.repository.finish({...f.args, outcome: 'accepted', providerMessageId: 'projects/fixture/messages/id'}), false);
});
test('known persisted provider result must contain the same message reference', async () => {
  const f = fixture();assert.equal(await f.repository.finish({...f.args, outcome: 'accepted',
    code: null, providerMessageId: 'projects/fixture/messages/id'}), true);
  f.state.finish.finish_notification_target_v2[0].provider_message_id = 'projects/fixture/messages/other';
  await assert.rejects(f.repository.finish({...f.args, outcome: 'accepted', providerMessageId: 'projects/fixture/messages/id'}), NotificationDispatchUnavailable);
});
for (const field of ['id', 'event_id', 'user_uid', 'installation_id', 'lease_token']) {
  test('foreign admission ' + field + ' cannot acknowledge a send', async () => {
    const f = fixture();f.state.admit.admit_notification_target_v2[0][field] = randomUUID();
    await assert.rejects(f.repository.admit(f.args), NotificationDispatchUnavailable);
  });
}
test('ambiguous typed responses fail rather than selecting the first destination', async () => {
  const f = fixture();f.state.admit.admit_notification_target_v2.push({...f.state.admit.admit_notification_target_v2[0]});
  await assert.rejects(f.repository.admit(f.args), NotificationDispatchUnavailable);
});
test('registration compare and set returns false for an already rotated token', async () => {
  const f = fixture();f.state.deactivate.deactivate_notification_registration_v2 = [];
  assert.equal(await f.repository.deactivate(f.args), false);
});
test('deactivation cannot acknowledge a different user installation', async () => {
  const f = fixture();f.state.deactivate.deactivate_notification_registration_v2[0].user_uid = randomUUID();
  await assert.rejects(f.repository.deactivate(f.args), NotificationDispatchUnavailable);
});
test('missing rollout row is unavailable instead of silently enabling dispatch', async () => {
  const f = fixture();f.state.enabled.notification_delivery_control_v2 = [];
  await assert.rejects(f.repository.enabled(), NotificationDispatchUnavailable);
});
test('a stuck response body is bounded and aborts without leaking its credentials', async () => {
  let signal;
  const repository = createNotificationRepositoryV2({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-secret', timeoutMs: 10, fetchImpl: async (_url, options) => {
      signal = options.signal;return {ok: true, json: () => new Promise(() => {})};
    }});
  await assert.rejects(repository.enabled(), error => error instanceof NotificationDispatchUnavailable && !error.message.includes('secret'));
  assert.equal(signal.aborted, true);
});
test('outer worker cancellation aborts repository transport too', async () => {
  const controller = new AbortController();let signal;
  const repository = createNotificationRepositoryV2({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-secret', fetchImpl: async (_url, options) => {
      signal = options.signal;controller.abort();return new Promise(() => {});
    }});
  await assert.rejects(repository.enabled({signal: controller.signal}), NotificationDispatchUnavailable);
  assert.equal(signal.aborted, true);
});
test('GraphQL errors expose no upstream patient or credential text', async () => {
  const repository = createNotificationRepositoryV2({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-secret', fetchImpl: async () => ({ok: true,
      json: async () => ({errors: [{message: 'private-clinic-and-token'}]})})});
  await assert.rejects(repository.enabled(), error => error instanceof NotificationDispatchUnavailable && !error.message.includes('private'));
});
