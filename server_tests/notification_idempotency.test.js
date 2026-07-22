const assert = require('node:assert/strict');
const test = require('node:test');

process.env.NHOST_GRAPHQL_URL = 'https://example.nhost.run/v1/graphql';
process.env.GRAPHQL_ADMIN_SECRET = 'test-only-admin-secret';

const {
  claimNotificationEvent,
  completeNotificationEvent,
  markNotificationDispatchStarted,
  resolveNotificationEventId,
} = require('../functions/_shared/notify_utils');

test('notification event identity is stable for Hasura retries', () => {
  const payload = {
    id: 'event-123',
    event: {op: 'INSERT'},
    table: {schema: 'public', name: 'patients'},
  };

  const first = resolveNotificationEventId(payload, 'new_patient', 'row-1');
  const replay = resolveNotificationEventId(payload, 'new_patient', 'row-1');
  const otherType = resolveNotificationEventId(payload, 'chat_message', 'row-1');

  assert.equal(first, replay);
  assert.match(first, /^nev1_[a-f0-9]{64}$/);
  assert.notEqual(first, otherType);
});

test('fallback identity includes table, operation, and row', () => {
  const insert = resolveNotificationEventId(
    {
      event: {op: 'INSERT'},
      table: {schema: 'public', name: 'chat_messages'},
    },
    'chat_message',
    'row-9',
  );
  const update = resolveNotificationEventId(
    {
      event: {op: 'UPDATE'},
      table: {schema: 'public', name: 'chat_messages'},
    },
    'chat_message',
    'row-9',
  );

  assert.notEqual(insert, update);
  assert.throws(
    () => resolveNotificationEventId({}, 'chat_message', ''),
    /missing_notification_event_identity/,
  );
});

test('claim succeeds only when the database returns the generated token', async (t) => {
  const originalFetch = global.fetch;
  t.after(() => {
    global.fetch = originalFetch;
  });

  let call = 0;
  global.fetch = async (_url, options) => {
    call += 1;
    const request = JSON.parse(options.body);
    const row = call === 1
      ? {
          event_id: request.variables.eventId,
          claim_token: request.variables.claimToken,
        }
      : null;
    return {
      json: async () => ({data: {claim_notification_event: row ? [row] : []}}),
    };
  };

  const first = await claimNotificationEvent('nev1_test', 'new_patient');
  const replay = await claimNotificationEvent('nev1_test', 'new_patient');

  assert.equal(first.claimed, true);
  assert.equal(replay.claimed, false);
  assert.notEqual(first.claimToken, replay.claimToken);
});

test('dispatch marker and completion persist only sanitized summaries', async (t) => {
  const originalFetch = global.fetch;
  t.after(() => {
    global.fetch = originalFetch;
  });

  const requests = [];
  global.fetch = async (_url, options) => {
    const request = JSON.parse(options.body);
    requests.push(request);
    return {
      json: async () => ({
        data: {update_notification_event_deliveries: {affected_rows: 1}},
      }),
    };
  };

  await markNotificationDispatchStarted('nev1_test', 'claim-1');
  await completeNotificationEvent('nev1_test', 'claim-1', {
    sent: 2,
    failed: 1,
    deactivated: 1,
    skipped: 'none',
    errors: ['sensitive-provider-response'],
  });

  assert.deepEqual(requests[0].variables.summary, {dispatch_started: true});
  assert.deepEqual(requests[1].variables.summary, {
    sent: 2,
    failed: 1,
    deactivated: 1,
    skipped: 'none',
  });
  assert.equal(JSON.stringify(requests).includes('sensitive-provider-response'), false);
});