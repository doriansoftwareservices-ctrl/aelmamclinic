const assert = require('node:assert/strict');
const test = require('node:test');

const userId = '44444444-4444-4444-8444-444444444444';
const accountId = '11111111-1111-4111-8111-111111111111';
const profile = {
  clinic_name: "Synthetic clinic's name", city_ar: 'مدينة', street_ar: 'شارع',
  near_ar: 'علامة', name_en: "Synthetic clinic's name", city_en: 'City',
  street_en: 'Street', near_en: 'Landmark', phone: '0000000000',
};

function loadHandler(sharedExports) {
  const shared = require.resolve('../functions/_shared/storage_utils');
  const entry = require.resolve('../functions/self-create-owner');
  const previous = require.cache[shared];
  require.cache[shared] = {id: shared, filename: shared, loaded: true,
    exports: sharedExports};
  delete require.cache[entry];
  try { return require(entry); }
  finally {
    if (previous) require.cache[shared] = previous;
    else delete require.cache[shared];
    delete require.cache[entry];
  }
}

async function attempt({membership = null, body = profile, authenticated = true,
  bearer = true, failCreate = false, failProfile = false} = {}) {
  const writes = [];
  const logs = [];
  const handler = loadHandler({
    readBody: async (req) => req.body,
    extractBearer: () => bearer ? 'owned-test-token' : null,
    resolveUserIdFromToken: async () => authenticated ? userId : null,
    runSql: async (sql, readOnly) => {
      if (readOnly) return {result: [['account_id', 'role', 'disabled'],
        ...(membership ? [[accountId, membership, 'f']] : [])]};
      writes.push(sql);
      // Model the PostgreSQL session contract that rejected the deployed
      // function. Only portable custom GUC names are accepted; request identity
      // is reset for each SQL transaction, never retained for the next call.
      const context = {};
      const setters = [...sql.matchAll(/set_config\('([^']+)',\s*'((?:[^']|'')*)',\s*(true|false)\)/g)];
      for (const [, name, encoded, local] of setters) {
        if (!/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$/.test(name)) {
          throw Error(`unrecognized configuration parameter ${name}`);
        }
        assert.equal(local, 'true', 'session identity must be transaction local');
        context[name] = encoded.replaceAll("''", "'");
      }
      const session = JSON.parse(context['hasura.user'] || '{}');
      assert.equal(session['x-hasura-user-id'], userId);
      assert.equal(session['x-hasura-role'], 'user');
      if ((failCreate && sql.includes('public.self_create_account(')) ||
          (failProfile && sql.includes('public.update_clinic_profile('))) {
        throw Error('run_sql failed: PRIVATE_SQL_CLINIC_CONTACT_AND_ADMIN_DETAIL');
      }
      return {result: [['id'], [accountId]]};
    },
  });
  const response = {statusCode: 200, body: null,
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
  const previous = console.error;
  console.error = (...args) => logs.push(args);
  try {
    await handler({method: 'POST', headers: bearer ? {authorization: 'Bearer owned-test-token'} : {}, body}, response);
    return {response, writes, logs};
  } finally { console.error = previous; }
}

test('new owner uses a portable transaction-local identity in both account and profile writes', async () => {
  const {response, writes} = await attempt({body: {...profile, user_uid: accountId, role: 'superadmin'}});
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.ok, true);
  assert.equal(response.body.created, true);
  assert.equal(response.body.account_id, accountId);
  assert.equal(response.body.profile_updated, true);
  assert.equal(writes.length, 2);
  assert.match(writes[0], /public\.self_create_account\(/);
  assert.match(writes[1], /public\.update_clinic_profile\(/);
  assert.match(writes[0], /Synthetic clinic''s name/);
});

test('existing owner only updates its profile with authenticated SQL identity', async () => {
  const {response, writes} = await attempt({membership: 'owner'});
  assert.equal(response.body.created, false);
  assert.equal(response.body.profile_updated, true);
  assert.equal(writes.length, 1);
});

test('employee membership cannot create or update an owner clinic', async () => {
  const {response, writes} = await attempt({membership: 'employee'});
  assert.equal(response.statusCode, 409);
  assert.equal(response.body.ok, false);
  assert.equal(writes.length, 0);
});

test('missing and unresolved bearer sessions do not write', async () => {
  for (const options of [{bearer: false}, {authenticated: false}]) {
    const {response, writes} = await attempt(options);
    assert.equal(response.statusCode, 401);
    assert.equal(writes.length, 0);
  }
});

test('incomplete new clinic profile does not write', async () => {
  const {response, writes} = await attempt({body: {clinic_name: 'Synthetic'}});
  assert.equal(response.statusCode, 400);
  assert.equal(writes.length, 0);
});

test('upstream creation failure exposes only a correlated public error', async () => {
  const {response, logs} = await attempt({failCreate: true});
  assert.equal(response.statusCode, 500);
  assert.equal(response.body.ok, false);
  assert.equal(response.body.error, 'self_create_owner_failed');
  assert.match(response.body.correlation_id, /^[0-9a-f-]{36}$/);
  assert.equal(logs.length, 1);
  assert.doesNotMatch(JSON.stringify([response.body, logs]), /PRIVATE_SQL|run_sql failed|Synthetic clinic/);
});

test('profile failure preserves the created account and redacts upstream SQL details', async () => {
  const {response, writes, logs} = await attempt({failProfile: true});
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.created, true);
  assert.equal(response.body.account_id, accountId);
  assert.equal(response.body.profile_updated, false);
  assert.equal(response.body.profile_update_error, 'clinic_profile_update_failed');
  assert.equal(writes.length, 2);
  assert.equal(logs.length, 1);
  assert.doesNotMatch(JSON.stringify([response.body, logs]), /PRIVATE_SQL|run_sql failed|Synthetic clinic/);
});
