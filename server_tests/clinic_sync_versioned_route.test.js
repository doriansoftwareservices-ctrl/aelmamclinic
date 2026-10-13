const assert = require('node:assert/strict');
const test = require('node:test');
const shared = require.resolve('../functions/_shared/storage_utils');
const previous = require.cache[shared];
let reads = 0;
let seenHeaders;
require.cache[shared] = {id: shared, filename: shared, loaded: true,
  exports: {readBody: async req => {
    reads++;
    return typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  }, extractBearer: req => {seenHeaders = req.headers; return 'fixture';},
  resolveUserIdFromToken: async () => '20000000-0000-4000-8000-000000000001'},
};
const handler = require('../functions/clinic-sync-v2');
if (previous) require.cache[shared] = previous;
else delete require.cache[shared];

function reply() {
  return {statusCode: 0, body: null,
    status(value) {this.statusCode = value; return this;},
    json(value) {this.body = value; return this;},
  };
}
test('the v2 route rejects legacy or amendment requests before any upstream call', async () => {
  const original = global.fetch;
  let calls = 0;
  global.fetch = async () => {calls++; throw new Error('Unexpected upstream call');};
  try {
    for (const body of [{}, {sync_protocol: 1}, {sync_protocol: 2, operation_type: 'amend_purchase'}]) {
      const response = reply();
      await handler({method: 'POST', body}, response);
      assert.equal(response.statusCode, 400);
      assert.equal(response.body.error_code, 'invalid_sync_protocol');
    }
    assert.equal(calls, 0);
  } finally {global.fetch = original;}
});
test('the versioned route rejects unsupported HTTP methods', async () => {
  const response = reply();
  await handler({method: 'GET'}, response);
  assert.equal(response.statusCode, 405);
});
test('a parsed body is forwarded once with the original headers', async () => {
  reads = 0;
  const response = reply();
  const headers = {authorization: 'Bearer fixture'};
  await handler({method: 'POST', headers, body: JSON.stringify({sync_protocol: 2})}, response);
  // The delegated handler rejects the incomplete request, after receiving the
  // already parsed object; it never attempts to reread an exhausted stream.
  assert.equal(response.statusCode, 400);
  assert.equal(response.body.error_code, 'invalid_sync_request');
  assert.equal(reads, 2);
  assert.equal(seenHeaders, headers);
});
