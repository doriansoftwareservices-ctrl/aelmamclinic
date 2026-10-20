const assert = require('node:assert/strict');
const test = require('node:test');

const fileId = '11111111-1111-4111-8111-111111111111';
const accountId = '22222222-2222-4222-8222-222222222222';
const conversationId = '33333333-3333-4333-8333-333333333333';
const messageId = '44444444-4444-4444-8444-444444444444';
const actorId = '55555555-5555-4555-8555-555555555555';
const storageUrl = 'https://fixture.storage.invalid/v1';
const signedUrl = `${storageUrl}/files/${fileId}/presignedurl/contents?fixture=synthetic`;

async function attempt({action = 'sign', allowed = true, frozen = false,
  registered = true, storageReady = true, storageStatus = 200,
  expiration = 120} = {}) {
  const shared = require.resolve('../functions/_shared/storage_utils');
  const entry = require.resolve('../functions/chat-attachment-access');
  const previousModule = require.cache[shared];
  const previousFetch = global.fetch;
  const calls = [];
  require.cache[shared] = {id: shared, filename: shared, loaded: true, exports: {
    readBody: async (req) => req.body,
    extractBearer: () => 'synthetic-session',
    resolveUserIdFromToken: async () => actorId,
    getChatAccess: async () => ({allowed, accountId, accountFrozen: frozen}),
    adminSecret: () => storageReady ? 'synthetic-server-only-secret' : null,
    resolveStorageUrl: () => storageReady ? storageUrl : null,
    runSql: async (_sql, readOnly) => {
      assert.equal(readOnly, true);
      return {result: [['id', 'bucket_id', 'name', 'account_id', 'conversation_id',
        'message_id', 'uploaded_by', 'security_state'],
      ...(registered ? [[fileId, 'chat-images', `attachments/${conversationId}/${messageId}/tiny.txt`,
        accountId, conversationId, messageId, actorId, 'active']] : [])]};
    },
  }};
  global.fetch = async (url, options) => {
    calls.push({url, options});
    // The Nhost Storage OpenAPI exposes GET /files/{id}/presignedurl.
    const correctRoute = url === `${storageUrl}/files/${fileId}/presignedurl` &&
      options.method === 'GET';
    return {ok: correctRoute && storageStatus === 200, status: correctRoute ? storageStatus : 404,
      json: async () => ({url: signedUrl, expiration})};
  };
  delete require.cache[entry];
  const response = {statusCode: 200, body: null,
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
  try {
    const handler = require(entry);
    await handler({method: 'POST', body: {action, file_id: fileId, expires_in: 60}}, response);
    return {response, calls};
  } finally {
    global.fetch = previousFetch;
    if (previousModule) require.cache[shared] = previousModule;
    else delete require.cache[shared];
    delete require.cache[entry];
  }
}

test('authorized participant signs through the deployed Storage GET contract', async () => {
  const {response, calls} = await attempt();
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.file_id, fileId);
  assert.equal(response.body.signed_url, signedUrl);
  assert.equal(response.body.expires_in, 120, 'Report the actual bucket expiration');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.headers['x-hasura-admin-secret'], 'synthetic-server-only-secret');
  assert.equal(calls[0].options.body, undefined);
});

test('resolving an owned upload does not depend on signing or Storage availability', async () => {
  const {response, calls} = await attempt({action: 'resolve', storageReady: false});
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.file_id, fileId);
  assert.equal(response.body.signed_url, undefined);
  assert.equal(calls.length, 0);
});

for (const action of ['sign', 'resolve']) {
  test(`outsider cannot ${action} an attachment or reach the signing service`, async () => {
    const {response, calls} = await attempt({action, allowed: false});
    assert.equal(response.statusCode, 403);
    assert.equal(response.body.error, 'forbidden');
    assert.equal(calls.length, 0);
  });
}

test('frozen clinic remains blocked before signing', async () => {
  const {response, calls} = await attempt({allowed: false, frozen: true});
  assert.equal(response.statusCode, 423);
  assert.equal(calls.length, 0);
});

test('missing registered ownership cannot fall back to an unrestricted file URL', async () => {
  const {response, calls} = await attempt({registered: false});
  assert.equal(response.statusCode, 404);
  assert.equal(calls.length, 0);
});

test('a rejected Storage response returns a controlled signing failure', async () => {
  const {response, calls} = await attempt({storageStatus: 401});
  assert.equal(response.statusCode, 502);
  assert.equal(response.body.error, 'storage_sign_failed');
  assert.equal(response.body.signed_url, undefined);
  assert.equal(calls.length, 1);
});

test('invalid Storage expiration does not publish a misleading signed URL', async () => {
  const {response} = await attempt({expiration: 0});
  assert.equal(response.statusCode, 502);
  assert.equal(response.body.error, 'storage_sign_failed');
});
