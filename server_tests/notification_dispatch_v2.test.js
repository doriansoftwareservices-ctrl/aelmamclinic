'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {dispatchNotificationBatchV2, NotificationDispatchUnavailable} =
  require('../functions/_shared/notification_dispatch_v2');

const providerId = 'projects/fixture/messages/known-acceptance';
function destination() {
  const event = {event_id: 'nev2_' + 'a'.repeat(64), event_type: 'new_patient',
    source_id: randomUUID(), account_id: randomUUID()};
  return {id: randomUUID(), user_uid: randomUUID(), token_id: randomUUID(),
    installation_id: randomUUID(), ack_nonce: randomUUID(), lease_token: randomUUID(),
    status: 'processing', attempts: 1, event_id: event.event_id, delivery_event: event};
}
function fixture(count = 1) {
  const targets = Array.from({length: count}, destination);
  const calls = [];
  const saved = new Map();
  const repository = {
    enabled: async () => true,
    claim: async ({limit}) => {calls.push('claim');assert.ok(count <= limit);return targets;},
    admit: async ({target}) => {calls.push(['admit', target.id]);return true;},
    finish: async args => {calls.push(['finish', args.target.id, args.outcome]);saved.set(args.target.id, args);return true;},
    deactivate: async args => {calls.push(['deactivate', args]);return true;},
  };
  const resolveAuthority = async target => ({allowed: true, recipientUid: target.user_uid,
    sourceId: target.delivery_event.source_id, accountId: target.delivery_event.account_id,
    kind: target.delivery_event.event_type, registrationId: target.token_id,
    transportToken: 'synthetic-' + target.id});
  const send = async args => {calls.push(['send', args]);return {outcome: 'accepted', providerMessageId: providerId};};
  return {targets, calls, saved, repository, resolveAuthority, send,
    run(overrides = {}) {return dispatchNotificationBatchV2({...this, ...overrides});}};
}

test('disabled protocol performs no claim or external effect', async () => {
  const f = fixture();f.repository.enabled = async () => false;
  assert.equal((await f.run()).disabled, true);
  assert.deepEqual(f.calls, []);
});
test('provider result is recorded after send and contains its actual message ID', async () => {
  const f = fixture();const result = await f.run();
  assert.deepEqual(f.calls.map(item => typeof item === 'string' ? item : item[0]),
    ['claim', 'admit', 'send', 'finish']);
  assert.equal(result.providerAccepted, 1);
  assert.equal(result.recordedAccepted, 1);
  assert.equal(f.saved.get(f.targets[0].id).providerMessageId, providerId);
  assert.equal(f.saved.get(f.targets[0].id).target.lease_token, f.targets[0].lease_token);
});
test('only stable routing identities reach the data payload, with no system notification', async () => {
  const f = fixture();await f.run();const request = f.calls.find(item => item[0] === 'send')[1];
  assert.deepEqual(request.data, {notification_protocol: '2', event_id: f.targets[0].event_id,
    target_id: f.targets[0].id, ack_nonce: f.targets[0].ack_nonce,
    recipient_uid: f.targets[0].user_uid, installation_id: f.targets[0].installation_id,
    account_id: f.targets[0].delivery_event.account_id, kind: 'new_patient',
    source_id: f.targets[0].delivery_event.source_id});
  assert.equal(Object.hasOwn(request, 'notification'), false);
  assert.equal(Object.hasOwn(request.data, 'body'), false);
  assert.ok(Object.isFrozen(request.data));
});
test('partial success finalizes only the successful target and retries the other', async () => {
  const f = fixture(2);
  const result = await f.run({send: async ({token}) => token.endsWith(f.targets[0].id)
    ? {outcome: 'accepted', providerMessageId: providerId} : {outcome: 'retryable'}});
  assert.equal(result.recordedAccepted, 1);assert.equal(result.retryable, 1);
  assert.equal(f.saved.get(f.targets[0].id).outcome, 'accepted');
  assert.equal(f.saved.get(f.targets[1].id).outcome, 'retryable');
});
test('revoked current authority cancels without provider or admission work', async () => {
  const f = fixture();const result = await f.run({resolveAuthority: async () => ({allowed: false, reason: 'membership_disabled'})});
  assert.equal(result.cancelled, 1);
  assert.deepEqual(f.calls.map(item => typeof item === 'string' ? item : item[0]), ['claim', 'finish']);
});
test('authority outage retries rather than cancelling the destination', async () => {
  const f = fixture();const result = await f.run({resolveAuthority: async () => {throw new Error('private-patient-or-JWT');}});
  assert.equal(result.retryable, 1);assert.equal(result.cancelled, 0);
  assert.equal(f.saved.get(f.targets[0].id).code, 'authority_unavailable');
  assert.ok(!JSON.stringify(result).includes('private'));
});
for (const change of [
  value => {value.recipientUid = randomUUID();},
  value => {value.accountId = randomUUID();},
  value => {value.sourceId = randomUUID();},
  value => {value.registrationId = 'invalid';},
]) {
  test('foreign or incomplete authority cannot dispatch', async () => {
    const f = fixture();const result = await f.run({resolveAuthority: async target => {
      const value = await f.resolveAuthority(target);change(value);return value;
    }});
    assert.equal(result.retryable, 1);assert.equal(f.calls.some(item => item[0] === 'send'), false);
  });
}
test('expiry, another worker or disabled admission never causes a send or acceptance', async () => {
  const f = fixture();f.repository.admit = async () => false;
  const result = await f.run();assert.equal(result.fenced, 1);
  assert.equal(f.saved.size, 0);assert.equal(f.calls.some(item => item[0] === 'send'), false);
});
test('admission transport failure remains retryable', async () => {
  const f = fixture();f.repository.admit = async () => {throw new Error('private DB');};
  assert.equal((await f.run()).retryable, 1);
  assert.equal(f.saved.get(f.targets[0].id).code, 'admission_unavailable');
});
test('a provider outage does not write accepted before or after a failed send', async () => {
  const f = fixture();assert.equal((await f.run({send: async () => {throw new Error('private provider body');}})).retryable, 1);
  assert.equal(f.saved.get(f.targets[0].id).outcome, 'retryable');
});
for (const response of [{outcome: 'accepted'}, {outcome: 'accepted', providerMessageId: 'not-a-message-id'}, {}, null]) {
  test('an unknown or unidentifiable provider response cannot complete a target', async () => {
    const f = fixture();const result = await f.run({send: async () => response});
    assert.equal(result.recordedAccepted, 0);assert.equal(result.retryable, 1);
  });
}
test('send then persistence failure remains unconfirmed with immutable retry identity', async () => {
  const f = fixture();const original = structuredClone(f.targets[0]);
  f.repository.finish = async () => {throw new Error('simulate crash or lost DB response');};
  const result = await f.run();assert.equal(result.providerAccepted, 1);
  assert.equal(result.recordedAccepted, 0);assert.equal(result.unconfirmed, 1);
  assert.deepEqual(f.targets[0], original);
});
test('a late worker cannot treat an empty typed outcome as successful persistence', async () => {
  const f = fixture();f.repository.finish = async () => false;
  const result = await f.run();assert.equal(result.providerAccepted, 1);
  assert.equal(result.recordedAccepted, 0);assert.equal(result.fenced, 1);
});
test('an invalid old token retires only its exact registration and retries rotation', async () => {
  const f = fixture();const rotated = randomUUID();
  const result = await f.run({resolveAuthority: async target => ({...await f.resolveAuthority(target), registrationId: rotated}),
    send: async () => ({outcome: 'unregistered'})});
  const cleanup = f.calls.find(item => item[0] === 'deactivate')[1];
  assert.equal(cleanup.registrationId, rotated);assert.equal(cleanup.target.user_uid, f.targets[0].user_uid);
  assert.equal(cleanup.target.installation_id, f.targets[0].installation_id);
  assert.equal(cleanup.token, 'synthetic-' + f.targets[0].id);
  assert.equal(result.retryable, 1);assert.equal(result.cancelled, 0);
});
test('unavailable token cleanup preserves retry rather than assuming success', async () => {
  const f = fixture();f.repository.deactivate = async () => {throw new Error('private DB');};
  const result = await f.run({send: async () => ({outcome: 'unregistered'})});
  assert.equal(result.retryable, 1);assert.equal(f.saved.get(f.targets[0].id).code, 'registration_cleanup_unavailable');
});
test('an invalid or duplicate claimed target rejects the whole batch before send', async () => {
  for (const duplicate of [false, true]) {
    const f = fixture(2);
    if (duplicate) f.targets[1] = f.targets[0];else f.targets[1].installation_id = null;
    await assert.rejects(f.run(), NotificationDispatchUnavailable);
    assert.equal(f.calls.some(item => item[0] === 'send'), false);
  }
});
test('bounded provider timeout aborts its transport and keeps the target retryable', async () => {
  const f = fixture();let signal;
  const result = await f.run({operationTimeouts: {send: 10}, send: async request => {
    signal = request.signal;return new Promise(() => {});
  }});
  assert.equal(signal.aborted, true);assert.equal(result.retryable, 1);
});
test('pre-claim errors are sanitized and cannot leak credentials', async () => {
  const f = fixture();f.repository.enabled = async () => {throw new Error('secret-url-or-token');};
  await assert.rejects(f.run(), error => error instanceof NotificationDispatchUnavailable &&
    !error.message.includes('secret'));
});
