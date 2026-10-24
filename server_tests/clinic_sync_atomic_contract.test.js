const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

const account = '11111111-1111-4111-8111-111111111111';
const actor = '22222222-2222-4222-8222-222222222222';
const remote = '33333333-3333-4333-8333-333333333333';
const event = '44444444-4444-4444-8444-444444444444';
const shared = require.resolve('../functions/_shared/storage_utils');
const priorModule = require.cache[shared];
require.cache[shared] = {
  id: shared, filename: shared, loaded: true,
  exports: {readBody: async req => req.body, extractBearer: () => 'fixture',
    resolveUserIdFromToken: async () => actor},
};
let handler;
if (process.env.ELMAM_SYNC_HANDLER_FIXTURE_PATH) {
  const filename = require.resolve('../functions/clinic-sync');
  const fixture = new Module(filename, module);
  fixture.filename = filename;
  fixture.paths = Module._nodeModulePaths(path.dirname(filename));
  fixture._compile(fs.readFileSync(process.env.ELMAM_SYNC_HANDLER_FIXTURE_PATH, 'utf8'), filename);
  handler = fixture.exports;
} else {
  handler = require('../functions/clinic-sync');
}
if (priorModule) require.cache[shared] = priorModule;
else delete require.cache[shared];

async function attempt({expected = '7', header = expected, existing = true,
  protocol = 2, error, receipt, denied = false, missingAck = false, table = 'item_types', money, fields = {}, legacyPrepared = false, method = 'POST'} = {}) {
  const originalFetch = global.fetch;
  const originalSecret = process.env.NHOST_ADMIN_SECRET;
  process.env.NHOST_ADMIN_SECRET = 'synthetic-only';
  const requests = [];
  const acknowledgement = legacyPrepared && receipt ? receipt : {
    success: true, operation: existing ? 'update_item_type' : 'create_item_type',
    server_timestamp: '2026-10-12T01:02:03.123456+00:00',
    data: {account_id: account, entity_table: table,
      client_mutation_id: 'opaque-N-1-cid', remote_id: remote,
      server_version: '42', sync_event_id: event,
      server_row: {id: remote, account_id: account, device_id: 'fixture',
        local_id: '7', server_version: '42', name: 'committed'}},
  };
  let writes = 0;
  global.fetch = async (_url, options) => {
    const request = JSON.parse(options.body);
    requests.push(request);
    let data;
    if (request.query.includes('query SyncAccess')) {
      data = {account_users: [{role: 'owner', disabled: false}],
        accounts_by_pk: {id: account, frozen: false}, super_admins: [],
        user: {disabled: false}, account_feature_permissions: [{allow_all: true,
          can_create: !denied, can_update: !denied, can_delete: !denied}]};
    } else if (request.query.includes('query ExistingMutation')) {
      data = {client_mutations: receipt ? [{id: event,
        operation_type: acknowledgement.operation, result_json: receipt}] : []};
    } else if (request.query.includes('query ExistingSyncIdentity')) {
      data = {rows: existing ? [{id: remote, is_deleted: false}] : [],
        requested: existing ? [{id: remote, account_id: account}] : []};
    } else if (request.query.includes('mutation ClinicSyncApply')) {
      writes++;
      if (error) return {ok: true, text: async () => JSON.stringify({
        errors: [{message: `database exception: ${error}`,
          extensions: {code: 'constraint-violation'}}],
      })};
      data = request.query.includes('apply_clinic_sync_atomic')
        ? {rows: missingAck ? [] : [{result_json: acknowledgement}]}
        : {row: {id: remote, updated_at: acknowledgement.server_timestamp,
          server_version: 42}, event: {id: event}, clientMutation: {id: event}};
    } else throw new Error('Unexpected fixture operation');
    return {ok: true, text: async () => JSON.stringify({data})};
  };
  const reply = {statusCode: 0, body: null, headers: {},
    setHeader(name, value) {this.headers[name.toLowerCase()] = value;},
    status(status) {this.statusCode = status; return this;},
    json(body) {this.body = body; return this;},
  };
  const payload = {id: remote, name: 'input', ...fields};
  if (money !== undefined) payload.cost_minor = money;
  if (protocol === 2 && !legacyPrepared) payload.expected_server_version = expected;
  try {
    await handler({method, body: {
      operation_type: acknowledgement.operation, entity_table: table,
      account_id: account, device_id: 'fixture', local_id: '7',
      client_mutation_id: 'opaque-N-1-cid', payload,
      ...(protocol === 2 ? {sync_protocol: 2, expected_server_version: legacyPrepared ? null : header, ...(legacyPrepared ? {legacy_prepared: true} : {})} : {}),
    }}, reply);
    return {...reply, requests, writes, acknowledgement};
  } finally {
    global.fetch = originalFetch;
    if (originalSecret === undefined) delete process.env.NHOST_ADMIN_SECRET;
    else process.env.NHOST_ADMIN_SECRET = originalSecret;
  }
}

test('read-only deployment probe identifies the handler without any upstream call', async () => {
  const result = await attempt({method: 'GET'});
  assert.equal(result.statusCode, 405);
  assert.equal(result.headers['x-clinic-sync-contract'], 'clinic-temporal-v1');
  assert.equal(result.requests.length, 0);
  assert.equal(result.writes, 0);
});

test('success returns the committed version, timestamp and row from one atomic RPC', async () => {
  const result = await attempt();
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, result.acknowledgement);
  const writes = result.requests.filter(r => /^\s*mutation\b/.test(r.query));
  assert.equal(writes.length, 1);
  assert.match(writes[0].query, /apply_clinic_sync_atomic/);
  assert.equal(writes[0].variables.actor, actor);
  assert.equal(writes[0].variables.expectedVersion, '7');
  assert.equal(writes[0].variables.clientMutation.client_mutation_id, 'opaque-N-1-cid');
  assert.equal(Object.hasOwn(writes[0].variables.clientMutation, 'result_json'), false);
});
test('a new origin uses a zero precondition and receives the actual receipt', async () => {
  const result = await attempt({existing: false, expected: '0'});
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, result.acknowledgement);
  assert.equal(result.requests.at(-1).variables.expectedVersion, '0');
});
test('a full64 precondition reaches SQL as exact text', async () => {
  const result = await attempt({expected: '9223372036854775807'});
  assert.equal(result.statusCode, 200);
  assert.equal(result.requests.at(-1).variables.expectedVersion, '9223372036854775807');
});
for (const expected of [1.5, 9007199254740992, '07', '-1', '9223372036854775808', '7x']) {
  test(`invalid expected version ${expected} is rejected before writing`, async () => {
    const result = await attempt({expected});
    assert.equal(result.statusCode, 400);
    assert.equal(result.body.error_code, 'sync_expected_version_invalid');
    assert.equal(result.writes, 0);
  });
}
test('the version header must match the immutable prepared payload', async () => {
  const result = await attempt({expected: '7', header: '8'});
  assert.equal(result.statusCode, 400);
  assert.equal(result.writes, 0);
});
test('insufficient stock is a domain conflict without a success acknowledgement', async () => {
  const result = await attempt({table: 'consumptions', existing: false,
    error: 'inventory_stock_update_rejected'});
  assert.equal(result.statusCode, 409);
  assert.equal(result.body.error_code, 'inventory_stock_conflict');
  assert.equal(result.body.success, false);
  assert.equal(result.body.data, undefined);
  assert.equal(result.writes, 1);
});
test('unrelated upstream failures remain server errors rather than stock conflicts', async () => {
  const result = await attempt({table: 'consumptions', existing: false,
    error: 'unrelated_database_failure'});
  assert.equal(result.statusCode, 500);
  assert.equal(result.body.error_code, 'upstream_mutation_failed');
  assert.equal(result.body.success, false);
});
for (const code of ['sync_version_conflict', 'sync_version_unknown']) {
  test(`${code} remains an explicit conflict without a success acknowledgement`, async () => {
    const result = await attempt({error: code});
    assert.equal(result.statusCode, 409);
    assert.equal(result.body.error_code, code);
    assert.equal(result.body.success, false);
    assert.equal(result.body.data, undefined);
  });
}
test('SQL authority revocation after the initial access check is enforced', async () => {
  const result = await attempt({error: 'sync_atomic_denied'});
  assert.equal(result.statusCode, 403);
  assert.equal(result.body.error_code, 'sync_atomic_denied');
});
test('a missing atomic receipt cannot be acknowledged as success', async () => {
  const result = await attempt({missingAck: true});
  assert.equal(result.statusCode, 500);
  assert.equal(result.body.success, false);
  assert.equal(result.body.data, undefined);
});
test('current authorization is checked before a legacy cached receipt', async () => {
  const result = await attempt({denied: true, protocol: 1, receipt: {success: true}});
  assert.equal(result.statusCode, 403);
  assert.equal(result.requests.length, 1);
  assert.equal(result.writes, 0);
});
test('a legacy cached receipt remains opaque and does not create another write', async () => {
  const receipt = {success: true, operation: 'update_item_type',
    server_timestamp: '2026-10-11T00:00:00Z', data: {
      entity_table: 'item_types', client_mutation_id: 'opaque-N-1-cid',
      remote_id: remote, sync_event_id: event, server_version: null,
    }};
  const result = await attempt({protocol: 1, receipt});
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, receipt);
  assert.equal(result.writes, 0);
});

for (const money of [9007199254740992, '9223372036854775808', '12.5']) {
  test(`invalid monetary minor ${money} cannot reach SQL`, async () => {
    const result = await attempt({table: 'medical_services', money});
    assert.equal(result.statusCode, 400);
    assert.equal(result.body.error_code, 'invalid_sync_money');
    assert.equal(result.writes, 0);
  });
}
test('a canonical full64 monetary minor reaches SQL without number conversion', async () => {
  const result = await attempt({table: 'medical_services', money: '9223372036854775807'});
  assert.equal(result.statusCode, 200);
  assert.equal(result.requests.at(-1).variables.object.cost_minor, '9223372036854775807');
});

test('a frozen legacy receipt is rechecked in SQL with its original unknown version', async () => {
  const receipt = {success: true, operation: 'update_item_type',
    server_timestamp: '2026-10-11T00:00:00Z', data: {
      entity_table: 'item_types', client_mutation_id: 'opaque-N-1-cid',
      remote_id: remote, sync_event_id: event, server_version: null,
    }};
  const result = await attempt({legacyPrepared: true, receipt});
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, receipt);
  assert.match(result.requests.at(-1).query, /apply_clinic_sync_atomic/);
  assert.equal(result.requests.at(-1).variables.expectedVersion, null);
});


test('patient exact registration reaches the atomic RPC without losing microseconds', async () => {
  const stamp = '2026-10-21T21:15:00.123456Z';
  const result = await attempt({table: 'patients', fields: {
    registered_at: stamp, register_date: '2026-10-22',
  }});
  assert.equal(result.statusCode, 200);
  const mutation = result.requests.find(request => request.query.includes('mutation ClinicSyncApply'));
  assert.equal(mutation.variables.object.registered_at, stamp);
  assert.equal(mutation.variables.object.register_date, '2026-10-22');
});

for (const code of ['clinic_timestamp_utc_required', 'clinic_timestamp_invalid',
  'patient_registration_time_required', 'patient_registration_time_clear_denied']) {
  test(`temporal contract rejection ${code} is a typed HTTP400 response`, async () => {
    const result = await attempt({table: 'patients', error: code});
    assert.equal(result.statusCode, 400);
    assert.equal(result.body.error_code, code);
    assert.equal(result.writes, 1);
    assert.equal(result.requests.filter(request => /^\s*mutation\b/.test(request.query)).length, 1);
  });
}

for(const code of ['patient_registration_paid_period_locked','patient_registration_financial_review_required']) {
 test('paid registration correction '+code+' remains a typed financial conflict',async()=>{
  const result=await attempt({table:'patients',error:code});
  assert.equal(result.statusCode,409);assert.equal(result.body.error_code,code);
  assert.equal(result.writes,1);
  assert.equal(result.requests.filter(request=>/^\s*mutation\b/.test(request.query)).length,1);
 });
}
