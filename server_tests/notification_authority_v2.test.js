'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {documents, resolveNotificationAuthority, createNotificationAuthorityQuery,
  NotificationAuthorityUnavailable} = require('../functions/_shared/notification_authority_v2');

const uid = '21000000-0000-4000-8000-000000000001';
const other = '21000000-0000-4000-8000-000000000002';
const account = '11000000-0000-4000-8000-000000000001';
const foreign = '11000000-0000-4000-8000-000000000002';
const token = '61000000-0000-4000-8000-000000000001';
const source = '31000000-0000-4000-8000-000000000001';
const doctor = '51000000-0000-4000-8000-000000000001';
const room = '71000000-0000-4000-8000-000000000001';

function fixture({kind = 'new_patient', change = () => {}, unavailable = null} = {}) {
  const target = {user_uid: uid, token_id: token,
    delivery_event: {event_type: kind, source_id: source, account_id: account}};
  const state = {
    identity: {user: {id: uid, disabled: false}, super_admins: [],
      push_device_tokens_by_pk: {id: token, user_uid: uid, account_id: account,
        is_active: true, platform: 'android', token: 'synthetic-token', locale_code: 'en',
        role: 'superadmin'}},
    patient: {patients: [{id: source, account_id: account, doctor_id: doctor}]},
    doctor: {doctors: [{id: doctor, account_id: account, user_uid: uid}]},
    message: {chat_messages: [{id: source, account_id: account,
      conversation_id: room, sender_uid: other}]},
    participant: {chat_participants: [{user_uid: uid, muted: false, archived: false, blocked: false}]},
    plan: {subscription_requests: [{id: source, account_id: account,
      status: 'pending', plan_code: 'free'}]},
    seat: {employee_seat_requests: [{id: source, account_id: account,
      status: 'submitted', seat_kind: 'extra'}]},
  };
  change(state, target);
  const calls = [];
  const query = async request => {
    const name = Object.keys(documents).find(key => documents[key] === request.document);
    assert.ok(name);
    calls.push({name, ...request});
    if (name === unavailable) throw new Error('private upstream detail must not escape');
    return structuredClone(state[name]);
  };
  return {target, calls, state, run: () => resolveNotificationAuthority(target, {query})};
}

test('patient source uses current recipient permissions rather than unrestricted admin access', async () => {
  const f = fixture();
  const result = await f.run();
  assert.equal(result.allowed, true);
  assert.equal(result.sourceId, source);
  assert.equal(result.locale, 'en');
  assert.deepEqual(f.calls.find(c => c.name === 'patient').actor, {uid, role: 'user'});
  assert.equal(f.calls.find(c => c.name === 'doctor').actor, null);
});

for (const [name, change, reason] of [
  ['disabled Auth', s => {s.identity.user.disabled = true;}, 'recipient_disabled'],
  ['deleted Auth', s => {s.identity.user = null;}, 'recipient_unavailable'],
  ['inactive token', s => {s.identity.push_device_tokens_by_pk.is_active = false;}, 'registration_inactive_or_rebound'],
  ['token reassigned after account change', s => {s.identity.push_device_tokens_by_pk.user_uid = other;}, 'registration_inactive_or_rebound'],
  ['removed token', s => {s.identity.push_device_tokens_by_pk = null;}, 'registration_unavailable'],
  ['revoked feature or frozen clinic', s => {s.patient.patients = [];}, 'source_not_visible'],
  ['changed assigned doctor', s => {s.doctor.doctors[0].user_uid = other;}, 'assignment_changed'],
  ['doctor from another clinic', s => {s.doctor.doctors[0].account_id = foreign;}, 'assignment_changed'],
  ['no assigned doctor', s => {s.patient.patients[0].doctor_id = null;}, 'doctor_not_assigned'],
  ['source moved outside captured clinic', s => {s.patient.patients[0].account_id = foreign;s.doctor.doctors[0].account_id = foreign;}, 'source_scope_changed'],
]) {
  test(name + ' suppresses delivery', async () => {
    const result = await fixture({change}).run();
    assert.deepEqual(result, {allowed: false, reason});
  });
}

test('transient/schema failure cannot become permanent cancellation or admin fallback', async () => {
  const f = fixture({unavailable: 'patient'});
  await assert.rejects(f.run(), error => error instanceof NotificationAuthorityUnavailable &&
    error.retryable && !error.message.includes('private'));
  assert.deepEqual(f.calls.map(c => c.name), ['identity', 'patient']);
});

test('untrusted token role cannot grant superadmin notifications', async () => {
  const f = fixture({kind: 'plan_request'});
  assert.deepEqual(await f.run(), {allowed: false, reason: 'active_superadmin_required'});
  assert.deepEqual(f.calls.map(c => c.name), ['identity']);
});

for (const kind of ['plan_request', 'seat_request']) {
  test('active registry authorizes ' + kind + ' using its real role', async () => {
    const f = fixture({kind, change: s => {s.identity.super_admins = [{user_uid: uid}];}});
    assert.equal((await f.run()).allowed, true);
    assert.deepEqual(f.calls.at(-1).actor, {uid, role: 'superadmin'});
  });
  test('handled ' + kind + ' does not send an obsolete alert', async () => {
    const f = fixture({kind, change: s => {
      s.identity.super_admins = [{user_uid: uid}];
      (kind === 'plan_request' ? s.plan.subscription_requests : s.seat.employee_seat_requests)[0].status = 'approved';
    }});
    assert.deepEqual(await f.run(), {allowed: false, reason: 'request_already_handled'});
  });
}

test('chat recipient must still participate even when it is a global administrator', async () => {
  const f = fixture({kind: 'chat_message', change: s => {
    s.identity.super_admins = [{user_uid: uid}];s.participant.chat_participants = [];
  }});
  assert.deepEqual(await f.run(), {allowed: false, reason: 'participant_removed'});
});
test('current chat source keeps opaque conversation identity', async () => {
  const f = fixture({kind: 'chat_message'});
  assert.equal((await f.run()).conversationId, room);
});
test('sender does not receive its own new-message notification', async () => {
  const f = fixture({kind: 'chat_message', change: s => {s.message.chat_messages[0].sender_uid = uid;}});
  assert.deepEqual(await f.run(), {allowed: false, reason: 'self_message'});
});

for (const change of [
  s => {s.identity.user.id = other;},
  s => {s.identity.super_admins = [{user_uid: other}];},
  s => {delete s.identity.push_device_tokens_by_pk;},
  s => {s.patient.patients[0].id = other;},
  s => {delete s.patient.patients[0].account_id;},
  s => {delete s.patient.patients[0].doctor_id;},
]) {
  test('incomplete or foreign response is unavailable rather than authorized', async () => {
    await assert.rejects(fixture({change}).run(), NotificationAuthorityUnavailable);
  });
}

test('query client keeps concurrent actor headers independent and immutable', async () => {
  const headers = [];
  const query = createNotificationAuthorityQuery({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-admin', fetchImpl: async (_url, options) => {
      headers.push(options.headers);
      await Promise.resolve();
      return {ok: true, json: async () => ({data: {actor: options.headers['x-hasura-user-id']}})};
    }});
  const results = await Promise.all([uid, other].map(actor => query({document: 'query Actor {__typename}', actor: {uid: actor, role: 'user'}})));
  assert.deepEqual(results.map(r => r.actor), [uid, other]);
  assert.notEqual(headers[0], headers[1]);
  assert.ok(headers.every(Object.isFrozen));
});
test('read client rejects mutations before transport', async () => {
  let calls = 0;
  const query = createNotificationAuthorityQuery({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-admin', fetchImpl: async () => {calls++;}});
  await assert.rejects(query({document: 'mutation {__typename}'}), NotificationAuthorityUnavailable);
  assert.equal(calls, 0);
});
test('hung transport is bounded and aborted', async () => {
  let signal;
  const query = createNotificationAuthorityQuery({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-admin', timeoutMs: 15, fetchImpl: async (_url, options) => {
      signal = options.signal;return new Promise(() => {});
    }});
  await assert.rejects(query({document: 'query Probe {__typename}'}), NotificationAuthorityUnavailable);
  assert.equal(signal.aborted, true);
});
test('upstream errors expose neither response body nor credentials', async () => {
  const query = createNotificationAuthorityQuery({url: 'https://fixture.invalid/v1/graphql',
    adminSecret: 'synthetic-admin', fetchImpl: async () => ({ok: false,
      json: async () => ({errors: [{message: 'private-token-and-patient-data'}]})})});
  await assert.rejects(query({document: 'query Probe {__typename}'}), error =>
    error.code === 'notification_authority_unavailable' && !error.message.includes('private-token'));
});

const installation = '81000000-0000-4000-8000-000000000001';
function installationFixture(change = () => {}) {
  return fixture({change: (state, target) => {
    target.installation_id = installation;
    state.installation = {user: state.identity.user, super_admins: [],
      push_device_tokens: [{...state.identity.push_device_tokens_by_pk,
        id: other, installation_id: installation, delivery_protocol: 2,
        token: 'synthetic-rotated-token'}]};
    change(state, target);
  }});
}
test('retry resolves the current token of the original installation after rotation', async () => {
  const f = installationFixture();
  const result = await f.run();
  assert.equal(result.allowed, true);
  assert.equal(result.transportToken, 'synthetic-rotated-token');
  assert.equal(result.registrationId, other);
  assert.equal(f.target.token_id, token);
  assert.equal(f.calls[0].name, 'installation');
});
test('another installation cannot replace a removed original destination', async () => {
  const f = installationFixture(s => {s.installation.push_device_tokens = [];});
  assert.deepEqual(await f.run(), {allowed: false, reason: 'registration_unavailable'});
});
test('another user cannot inherit a destination on the same installation', async () => {
  const f = installationFixture(s => {s.installation.push_device_tokens[0].user_uid = other;});
  assert.deepEqual(await f.run(), {allowed: false, reason: 'registration_inactive_or_rebound'});
});
for (const change of [
  s => {s.installation.push_device_tokens[0].delivery_protocol = 1;},
  s => {s.installation.push_device_tokens[0].installation_id = other;},
  s => {s.installation.push_device_tokens.push({...s.installation.push_device_tokens[0]});},
]) {
  test('invalid or ambiguous installation reply cannot authorize delivery', async () => {
    await assert.rejects(installationFixture(change).run(), NotificationAuthorityUnavailable);
  });
}
test('registration moved to another clinic cannot receive a captured clinic event', async () => {
  const f = installationFixture(s => {s.installation.push_device_tokens[0].account_id = foreign;});
  assert.deepEqual(await f.run(), {allowed: false, reason: 'registration_scope_changed'});
});
for (const flag of ['muted', 'archived', 'blocked']) {
  test('current participant ' + flag + ' suppresses a retried chat notification', async () => {
    const f = fixture({kind: 'chat_message', change: s => {s.participant.chat_participants[0][flag] = true;}});
    assert.deepEqual(await f.run(), {allowed: false, reason: 'participant_notifications_disabled'});
  });
}
