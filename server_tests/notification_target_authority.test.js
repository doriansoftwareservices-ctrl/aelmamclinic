const assert = require('node:assert/strict');
const test = require('node:test');

// Handler-level local fixture. No Auth, Hasura, Storage or FCM request is made.
const sharedPath = require.resolve('../functions/_shared/notify_utils');
const originalShared = require(sharedPath);
const ids = {
  sender: '00000000-0000-4000-8000-000000000001',
  target: '00000000-0000-4000-8000-000000000002',
  clinic: '00000000-0000-4000-8000-000000000003',
  other: '00000000-0000-4000-8000-000000000004',
  room: '00000000-0000-4000-8000-000000000005',
  patient: '00000000-0000-4000-8000-000000000006',
  doctor: '00000000-0000-4000-8000-000000000007',
};

async function invoke(t, kind, options = {}) {
  const sent = [];
  const queries = [];
  const claims = [];
  const activeUsers = options.disabledAuth || options.missingAuth
    ? [] : [{ id: ids.target }];
  const memberships = options.disabledMember || options.missingMember ? [] : [{
    user_uid: ids.target,
    account_id: options.otherMembership ? ids.other : ids.clinic,
    role: options.role || 'owner',
  }];
  const query = async (text, variables = {}) => {
    queries.push({ text, variables });
    if (text.includes('query Parts(')) return {
      chat_conversations_by_pk: options.missingRoom ? null : {
        account_id: options.tenant ? ids.clinic : null,
        created_by: options.selfCreated ? ids.target : ids.sender,
        is_group: !!options.group,
        is_deleted: !!options.deletedRoom,
      },
      chat_participants: [{
        user_uid: ids.target,
        archived: options.archived || false,
        muted: options.muted || false,
        role: options.participantRole || 'member',
        account_id: options.participantClinic ? ids.clinic : null,
      }],
    };
    if (text.includes('query ActiveChatTargets(')) {
      if (options.authorityUnavailable) throw new Error('local-authority-unavailable');
      return {
      users: activeUsers,
      account_users: memberships,
      super_admins: options.superadmin && !options.disabledSuperadmin
        ? [{ user_uid: ids.target }] : [],
      chat_support_agents: options.activeSupport ? [{ user_uid: ids.target }] : [],
      accounts_by_pk: options.missingClinic ? null : { frozen: !!options.frozen },
      };
    }
    if (text.includes('query ActiveChatClinics(')) return {
      accounts: options.frozen || options.missingClinic ? [] : variables.accounts.map((id) => ({ id })),
    };
    if (text.includes('query Doctor(')) return {
      doctors: [{ user_uid: ids.target, account_id: ids.clinic }],
    };
    if (text.includes('query ActiveDoctor(')) return {
      account_users: memberships,
      user: options.missingAuth ? null : { disabled: !!options.disabledAuth },
      accounts_by_pk: options.missingClinic ? null : { frozen: !!options.frozen },
    };
    if (text.includes('query Tokens(')) return {
      push_device_tokens: [{ token: 'local-fixture-token', locale_code: 'en' }],
    };
    throw new Error(`Unexpected fixture operation: ${text.split('\n')[0]}`);
  };
  require.cache[sharedPath].exports = {
    ...originalShared,
    readBody: async (req) => req.body,
    assertWebhookSecret: () => {},
    gqlRequest: query,
    sendFcm: async (tokens, payload) => {
      sent.push({ tokens, payload });
      return { sent: tokens.length, failed: 0, deactivated: 0 };
    },
    claimNotificationEvent: async (...args) => {
      claims.push(args);
      return { claimed: true, claimToken: 'local-claim' };
    },
    markNotificationDispatchStarted: async () => {},
    completeNotificationEvent: async () => {},
    failNotificationEvent: async () => {},
    logInfo: () => {},
    logWarn: () => {},
    logError: () => {},
  };
  const handlerPath = require.resolve(`../functions/${kind}/index`);
  delete require.cache[handlerPath];
  const handler = require(handlerPath);
  t.after(() => {
    require.cache[sharedPath].exports = originalShared;
    delete require.cache[handlerPath];
  });
  let response;
  let status = 200;
  const row = kind === 'notify-chat-message' ? {
    id: 'local-message',
    conversation_id: ids.room,
    sender_uid: ids.sender,
    account_id: options.eventAccount !== undefined
      ? options.eventAccount : (options.tenant ? ids.clinic : null),
  } : { id: ids.patient, doctor_id: ids.doctor, account_id: ids.clinic };
  await handler({ method: 'POST', body: { id: 'local-event', event: { data: { new: row } } } }, {
    status(code) { status = code; return this; },
    json(value) { response = value; return this; },
  });
  return { sent, queries, claims, response, status };
}

for (const [label, options] of [
  ['disabled Auth identity', { disabledAuth: true }],
  ['missing Auth identity', { missingAuth: true }],
  ['disabled clinic membership', { disabledMember: true }],
  ['removed clinic membership', { missingMember: true }],
  ['owner demoted to employee', { role: 'employee' }],
  ['owner clinic frozen', { frozen: true }],
  ['owner clinic removed', { missingClinic: true }],
  ['disabled superadmin without clinic', { superadmin: true, disabledSuperadmin: true, missingMember: true }],
  ['disabled Auth superadmin', { superadmin: true, disabledAuth: true, missingMember: true }],
  ['missing conversation', { missingRoom: true }],
]) {
  test(`global chat suppresses ${label} before token lookup or dispatch`, async (t) => {
    const result = await invoke(t, 'notify-chat-message', options);
    assert.equal(result.status, 200);
    assert.equal(result.sent.length, 0);
    assert.equal(result.claims.length, 0);
    assert.equal(result.queries.some((item) => item.text.includes('query Tokens(')), false);
  });
}

for (const [label, options] of [
  ['global owner', {}],
  ['global admin', { role: 'admin' }],
  ['global active superadmin without clinic', { superadmin: true, missingMember: true }],
  ['tenant owner', { tenant: true }],
  ['tenant employee', { tenant: true, role: 'employee' }],
]) {
  test(`${label} still receives a minimal localized notification`, async (t) => {
    const result = await invoke(t, 'notify-chat-message', options);
    assert.equal(result.status, 200);
    assert.equal(result.sent.length, 1);
    assert.equal(result.sent[0].payload.data.conversation_id, ids.room);
    assert.equal(result.sent[0].payload.notification.body, 'You have a new message.');
  });
}

for (const options of [{ archived: true }, { muted: true }]) {
  test(`global chat preserves ${Object.keys(options)[0]} suppression`, async (t) => {
    const result = await invoke(t, 'notify-chat-message', options);
    assert.equal(result.sent.length, 0);
  });
}

test('tenant event cannot bypass authority by presenting a null account', async (t) => {
  const result = await invoke(t, 'notify-chat-message', {
    tenant: true, eventAccount: null, disabledMember: true,
  });
  assert.equal(result.sent.length, 0);
});

test('tenant notification rejects membership in a different clinic', async (t) => {
  const result = await invoke(t, 'notify-chat-message', {
    tenant: true, otherMembership: true,
  });
  assert.equal(result.sent.length, 0);
});

test('chat notification fails closed when current authority is unavailable', async (t) => {
  const result = await invoke(t, 'notify-chat-message', { authorityUnavailable: true });
  assert.equal(result.status, 500);
  assert.equal(result.sent.length, 0);
  assert.equal(result.claims.length, 0);
});

test('clinic discovery is batched and restricted to candidate memberships', async (t) => {
  const result = await invoke(t, 'notify-chat-message');
  const clinics = result.queries.filter((item) => item.text.includes('query ActiveChatClinics('));
  assert.equal(clinics.length, 1);
  assert.deepEqual(clinics[0].variables.accounts, [ids.clinic]);
  assert.match(clinics[0].text, /id: \{_in: \$accounts\}/);
});

test('assigned active support receives its tenant-room notification without clinic membership', async (t) => {
  const result = await invoke(t, 'notify-chat-message', {
    tenant: true, missingMember: true, activeSupport: true, participantRole: 'admin',
  });
  assert.equal(result.status, 200);
  assert.equal(result.sent.length, 1);
  assert.equal(result.sent[0].payload.data.account_id, ids.clinic);
});

for (const [label, extra] of [
  ['revoked support assignment', { activeSupport: false }],
  ['disabled Auth', { disabledAuth: true }],
  ['frozen room clinic', { frozen: true }],
  ['missing room clinic', { missingClinic: true }],
  ['group room', { group: true }],
  ['self-created room', { selfCreated: true }],
  ['ordinary participant', { participantRole: 'member' }],
  ['clinic participant instead of support assignment', { participantClinic: true }],
  ['deleted conversation', { deletedRoom: true }],
]) {
  test(`support notification rejects ${label} before token lookup`, async (t) => {
    const result = await invoke(t, 'notify-chat-message', {
      tenant: true, missingMember: true, activeSupport: true, participantRole: 'admin', ...extra,
    });
    assert.equal(result.status, 200);
    assert.equal(result.sent.length, 0);
    assert.equal(result.claims.length, 0);
    assert.equal(result.queries.some((item) => item.text.includes('query Tokens(')), false);
  });
}

test('deleted conversation suppresses otherwise active clinic members', async (t) => {
  const result = await invoke(t, 'notify-chat-message', { tenant: true, deletedRoom: true });
  assert.equal(result.sent.length, 0);
  assert.equal(result.claims.length, 0);
});

for (const [label, options] of [
  ['disabled Auth identity', { disabledAuth: true }],
  ['missing Auth identity', { missingAuth: true }],
  ['disabled membership', { disabledMember: true }],
  ['frozen clinic', { frozen: true }],
  ['missing clinic', { missingClinic: true }],
]) {
  test(`patient notification suppresses ${label}`, async (t) => {
    const result = await invoke(t, 'notify-new-patient', options);
    assert.equal(result.status, 200);
    assert.equal(result.sent.length, 0);
    assert.equal(result.claims.length, 0);
  });
}

test('patient notification preserves active linked doctor delivery', async (t) => {
  const result = await invoke(t, 'notify-new-patient');
  assert.equal(result.status, 200);
  assert.equal(result.sent.length, 1);
  assert.equal(result.sent[0].payload.data.patient_id, ids.patient);
});
