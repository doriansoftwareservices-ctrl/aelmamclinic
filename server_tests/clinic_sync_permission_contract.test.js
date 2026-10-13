const assert = require('node:assert/strict');
const test = require('node:test');

const accountId = '11111111-1111-4111-8111-111111111111';
const otherAccountId = '22222222-2222-4222-8222-222222222222';
const remoteId = '33333333-3333-4333-8333-333333333333';
const userId = '44444444-4444-4444-8444-444444444444';
const shared = require.resolve('../functions/_shared/storage_utils');
const previous = require.cache[shared];
require.cache[shared] = {
  id: shared, filename: shared, loaded: true,
  exports: {
    readBody: async (req) => req.body,
    extractBearer: () => 'test-token',
    resolveUserIdFromToken: async () => userId,
  },
};
const handler = require('../functions/clinic-sync');
if (previous) require.cache[shared] = previous;
else delete require.cache[shared];

async function attempt({operationType, canCreate, canUpdate, existing, requestedAccount, canDelete = false, payload = {}, deleted = false, capture = false, localId = 7, role = 'staff'}) {
  const previousFetch = global.fetch;
  const previousSecret = process.env.NHOST_ADMIN_SECRET;
  process.env.NHOST_ADMIN_SECRET = 'test-only';
  let writes = 0;
  let wire;
  global.fetch = async (_url, options) => {
    const request = JSON.parse(options.body);
    const {query} = request;
    let data;
    if (query.includes('query SyncAccess')) {
      data = {
        account_users: [{role, disabled: false}],
        accounts_by_pk: {id: accountId, frozen: false},
        super_admins: [], user: {disabled: false},
        account_feature_permissions: [{
          allow_all: true, can_create: canCreate, can_update: canUpdate,
          can_delete: canDelete,
        }],
      };
    } else if (query.includes('query ExistingMutation')) {
      data = {client_mutations: []};
    } else if (query.includes('query ExistingSyncIdentity')) {
      data = {
        rows: existing ? [{id: remoteId, is_deleted: deleted}] : [],
        requested: requestedAccount ? [{id: remoteId, account_id: requestedAccount}] : [],
      };
    } else if (query.includes('mutation ClinicSyncApply')) {
      writes++;
      wire = request;
      data = {rows: [{result_json: {
        success: true, operation: operationType,
        server_timestamp: '2026-10-12T01:00:00Z',
        data: {entity_table: 'item_types', client_mutation_id: 'mutation-unique',
          remote_id: remoteId, server_version: '42',
          sync_event_id: '55555555-5555-4555-8555-555555555555'},
      }}]};
    } else {
      throw Error(`unexpected query: ${query.slice(0, 90)}`);
    }
    return {ok: true, text: async () => JSON.stringify({data})};
  };
  const reply = {statusCode: 0, body: null,
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
  try {
    await handler({method: 'POST', body: {
      operation_type: operationType, entity_table: 'item_types',
      client_mutation_id: 'mutation-unique', account_id: accountId,
      device_id: 'device-1', local_id: localId,
      sync_protocol: 2, expected_server_version: existing ? '7' : '0',
      payload: {id: remoteId, name: 'safe', expected_server_version: existing ? '7' : '0', ...payload},
    }}, reply);
    return {status: reply.statusCode, code: reply.body.error_code, writes, ...(capture ? {wire} : {})};
  } finally {
    global.fetch = previousFetch;
    if (previousSecret === undefined) delete process.env.NHOST_ADMIN_SECRET;
    else process.env.NHOST_ADMIN_SECRET = previousSecret;
  }
}

test('create privilege cannot update an existing identity by labeling it create', async () => {
  const result = await attempt({operationType: 'create_item_type',
    canCreate: true, canUpdate: false, existing: true, requestedAccount: accountId});
  assert.deepEqual(result, {status: 403, code: 'sync_update_denied', writes: 0});
});

test('update privilege cannot insert an absent identity by labeling it update', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: false, canUpdate: true, existing: false});
  assert.deepEqual(result, {status: 403, code: 'sync_create_denied', writes: 0});
});

test('foreign tenant UUID is rejected before mutation', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: true, canUpdate: true, existing: false,
    requestedAccount: otherAccountId});
  assert.deepEqual(result, {status: 403, code: 'foreign_sync_identity', writes: 0});
});

test('correctly owned existing identity can be updated', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: true, canUpdate: true, existing: true,
    requestedAccount: accountId});
  assert.deepEqual(result, {status: 200, code: undefined, writes: 1});
});

test('owner CRUD permission matches the permission returned to Flutter', async () => {
  const result = await attempt({operationType: 'create_item_type',
    canCreate: false, canUpdate: false, existing: false, role: 'owner'});
  assert.deepEqual(result, {status: 403, code: 'sync_create_denied', writes: 0});
});


test('update permission cannot smuggle a tombstone in a normal update', async () => {
  for (const value of [true, 1, 'true', '1']) {
    const result = await attempt({operationType: 'update_item_type',
      canCreate: false, canUpdate: true, existing: true,
      requestedAccount: accountId, payload: {is_deleted: value}});
    assert.deepEqual(result, {status: 403, code: 'sync_delete_denied', writes: 0});
  }
});

test('delete privilege still requires an explicit delete command', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: true, canUpdate: true, canDelete: true, existing: true,
    requestedAccount: accountId, payload: {is_deleted: true}});
  assert.deepEqual(result, {status: 400, code: 'tombstone_operation_required', writes: 0});
});

test('ordinary update never writes tombstone audit columns', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: true, canUpdate: true, existing: true, capture: true,
    requestedAccount: accountId, payload: {is_deleted: false,
      deleted_at: '2000-01-01T00:00:00Z', deleted_by_user_id: otherAccountId,
      deletion_client_mutation_id: 'forged'}});
  assert.equal(result.status, 200);
  for (const column of ['is_deleted', 'deleted_at', 'deleted_by_user_id',
    'deletion_client_mutation_id']) {
    assert.equal(Object.hasOwn(result.wire.variables.object, column), false);
    assert.equal(result.wire.query.includes(column), false);
  }
});

test('explicit deletion uses server-owned actor and deletion receipt', async () => {
  const result = await attempt({operationType: 'delete_item_type',
    canCreate: false, canUpdate: false, canDelete: true, existing: true,
    requestedAccount: accountId, capture: true,
    payload: {deleted_by_user_id: otherAccountId,
      deletion_client_mutation_id: 'forged', deleted_at: '2000-01-01T00:00:00Z'}});
  assert.equal(result.status, 200);
  assert.equal(result.wire.variables.object.is_deleted, true);
  assert.equal(result.wire.variables.object.deleted_by_user_id, userId);
  assert.equal(result.wire.variables.object.deletion_client_mutation_id, 'mutation-unique');
  assert.notEqual(result.wire.variables.object.deleted_at, '2000-01-01T00:00:00Z');
});

test('legacy 64-bit origin ID is preserved exactly through the handler', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: true, canUpdate: true, existing: true, capture: true,
    requestedAccount: accountId, localId: '985908158000000008'});
  assert.equal(result.status, 200);
  assert.equal(result.wire.variables.object.local_id, '985908158000000008');
});

test('unsafe numeric, malformed, zero, and overflowing identities fail before writes', async () => {
  for (const localId of [985908158000000008, 1.5, '1x', '-1', '0',
    '9223372036854775808', '999999999999999999999', null]) {
    const result = await attempt({operationType: 'update_item_type',
      canCreate: true, canUpdate: true, existing: true,
      requestedAccount: accountId, localId});
    assert.deepEqual(result, {status: 400, code: 'invalid_local_identity', writes: 0});
  }
});

test('a deleted record cannot be resurrected by an ordinary update', async () => {
  const result = await attempt({operationType: 'update_item_type',
    canCreate: true, canUpdate: true, existing: true, deleted: true,
    requestedAccount: accountId, payload: {is_deleted: false}});
  assert.deepEqual(result, {status: 409, code: 'sync_record_deleted', writes: 0});
});
