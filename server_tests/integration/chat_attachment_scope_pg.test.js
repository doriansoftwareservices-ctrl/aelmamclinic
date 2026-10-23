const assert = require('node:assert/strict');
const {execFile, execFileSync} = require('node:child_process');
const {EventEmitter} = require('node:events');
const fs = require('node:fs');
const https = require('node:https');
const path = require('node:path');
const test = require('node:test');

// Explicit integration target: only the new, private database made by the runner.
assert.equal(process.env.PGHOST, '127.0.0.1');
assert.match(process.env.PGDATABASE || '', /^elmam_chat_scope_fixture_[a-z0-9_]+$/);
assert.equal(process.env.PGUSER, 'elmam_chat_fixture');
assert.match(process.env.ELMAM_CHAT_FIXTURE_PSQL || '', /PostgreSQL[\\/]18\.6[\\/]bin[\\/]psql\.exe$/i);
assert.ok(fs.existsSync(process.env.ELMAM_CHAT_FIXTURE_PSQL));
assert.ok(Number(process.env.PGPORT) > 1024);
const root = path.resolve(__dirname, '../..');
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const tenant = uuid(31);
const globalRoom = uuid(32);
const account = uuid(1);
let actor = uuid(11);
let context = '';
let nextUpload = 80;
let revokeAfterUpload = false;
const storageCalls = [];

function rows(sql) {
  const query = sql.trim().replace(/;$/, '');
  const wrapped = `SELECT coalesce(json_agg(row_to_json(fixture_rows)), '[]'::json)::text FROM (${query}) fixture_rows;`;
  const input = context ? `BEGIN; ${context}; ${wrapped} ROLLBACK;` : wrapped;
  const output = execFileSync(process.env.ELMAM_CHAT_FIXTURE_PSQL,
    ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], {
      input, encoding: 'utf8', timeout: 10000,
      env: {...process.env, PGCONNECT_TIMEOUT: '3', PGOPTIONS: '-c statement_timeout=5000'},
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  return JSON.parse(output.trim());
}

function execute(sql) {
  execFileSync(process.env.ELMAM_CHAT_FIXTURE_PSQL,
    ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {input: sql, encoding: 'utf8', timeout: 10000,
      env: {...process.env, PGCONNECT_TIMEOUT: '3'}, stdio: ['pipe', 'pipe', 'pipe']});
}

assert.equal(rows('SELECT value FROM public.elmam_chat_fixture_marker')[0].value,
  'local_chat_attachment_scope_20261016');
for (const name of Object.keys(process.env)) {
  if (/^(NHOST_|HASURA_|GRAPHQL_ADMIN_SECRET$)/.test(name)) delete process.env[name];
}
process.env.NHOST_GRAPHQL_URL = 'https://fixture.graphql.nhost.run.invalid/v1/graphql';
process.env.NHOST_AUTH_URL = 'https://fixture.auth.nhost.run.invalid/v1';
process.env.NHOST_STORAGE_URL = 'https://fixture.storage.nhost.run.invalid/v1';
process.env.HASURA_GRAPHQL_ADMIN_SECRET = 'synthetic-server-only-secret';

const previousFetch = global.fetch;
const previousRequest = https.request;
global.fetch = async (url, options) => {
  const value = String(url);
  if (value === 'https://fixture.hasura.nhost.run.invalid/v2/query') {
    const body = JSON.parse(options.body);
    assert.equal(body.type, 'run_sql');
    assert.equal(body.args.source, 'default');
    let result;
    if (/^\s*delete\b/i.test(body.args.sql)) {
      assert.equal(body.args.read_only, false);
      assert.match(body.args.sql, /^\s*delete from public\.chat_attachment_file_ownership/i);
      execute(context ? `BEGIN; ${context}; ${body.args.sql} ROLLBACK;` : body.args.sql);
      result = [];
    } else {
      result = rows(body.args.sql);
    }
    return {ok: true, status: 200, text: async () => JSON.stringify({result: result.length
      ? [Object.keys(result[0]), ...result.map((row) => Object.values(row))] : [[]]})};
  }
  if (value === 'https://fixture.auth.nhost.run.invalid/v1/user') {
    assert.equal(options.method, 'GET');
    assert.equal(options.headers.Authorization, 'Bearer synthetic-session');
    return {ok: true, status: 200, json: async () => ({id: actor})};
  }
  if (/^https:\/\/fixture\.storage\.nhost\.run\.invalid\/v1\/files\/[0-9a-f-]+(?:\/presignedurl)?$/.test(value)) {
    storageCalls.push({url: value, method: options.method});
    if (options.method === 'DELETE') return {ok: true, status: 200};
    assert.equal(options.method, 'GET');
    assert.ok(value.endsWith('/presignedurl'));
    return {ok: true, status: 200, json: async () => ({
      url: 'https://signed.fixture.invalid/private-object', expiration: 120,
    })};
  }
  throw new Error(`Unexpected external request blocked by local fixture: ${value}`);
};

https.request = (options, callback) => {
  assert.equal(options.hostname, 'fixture.storage.nhost.run.invalid');
  assert.equal(options.method, 'POST');
  assert.equal(options.path, '/v1/files');
  const request = new EventEmitter();
  const chunks = [];
  request.setTimeout = () => request;
  request.write = (chunk) => chunks.push(chunk);
  request.end = () => {
    const multipart = Buffer.concat(chunks).toString('utf8');
    const match = multipart.match(/name="metadata\[\]"\r\n\r\n([^\r\n]+)/);
    assert.ok(match, 'Storage metadata must be present');
    const meta = JSON.parse(match[1]);
    const id = uuid(nextUpload++);
    assert.match(meta.name, /^attachments\/[0-9a-f-]+\/[0-9a-f-]+\/upload-fixture-\d+\.txt$/);
    execute(`INSERT INTO storage.files(id,bucket_id,name) VALUES ('${id}','chat-attachments','${meta.name}');`);
    storageCalls.push({method: 'POST', id, meta});
    if (revokeAfterUpload) context = `UPDATE public.account_users SET disabled=true WHERE user_uid='${actor}'`;
    queueMicrotask(() => {
      const response = new EventEmitter();
      response.statusCode = 201;
      callback(response);
      response.emit('data', JSON.stringify({processedFiles: [{id, name: meta.name}]}));
      response.emit('end');
    });
  };
  return request;
};

test.after(() => {
  global.fetch = previousFetch;
  https.request = previousRequest;
});
const shared = require(path.join(root, 'functions/_shared/storage_utils'));
const access = require(path.join(root, 'functions/chat-attachment-access'));
const upload = require(path.join(root, 'functions/admin-upload-chat-attachment'));

async function inContext(sql, operation) {
  const previous = context;
  context = sql;
  try { return await operation(); } finally { context = previous; }
}

function claim(overrides = {}) {
  return shared.updateChatFileOwnership({fileId: uuid(52), bucketId: 'chat-attachments',
    fileName: `attachments/${globalRoom}/${uuid(42)}/fixture.txt`, accountId: null,
    conversationId: globalRoom, messageId: uuid(42), uploadedByUserId: uuid(11), ...overrides});
}

async function attempt(handler, uid, body) {
  actor = uid;
  storageCalls.length = 0;
  const response = {statusCode: null, body: null,
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
  await handler({method: 'POST', headers: {authorization: 'Bearer synthetic-session'}, body}, response);
  return response;
}

function uploadBody(conversationId = globalRoom, messageId = uuid(42)) {
  return {filename: `upload-fixture-${nextUpload}.txt`, base64: Buffer.from('private local fixture').toString('base64'),
    bucketId: 'chat-attachments', mimeType: 'text/plain',
    metadata: {conversation_id: conversationId, message_id: messageId}};
}

test('cross-clinic owner access uses the joined global conversation', async () => {
  const result = await shared.getChatAccess(globalRoom, uuid(11));
  assert.equal(result.allowed, true);
  assert.equal(result.accountId, null);
});

test('cross-clinic file claim preserves a null conversation account', async () => {
  assert.equal(await claim(), true);
  const stored = rows(`SELECT account_id,conversation_id,message_id FROM public.chat_attachment_file_ownership WHERE file_id='${uuid(52)}'`)[0];
  assert.deepEqual(stored, {account_id: null, conversation_id: globalRoom, message_id: uuid(42)});
});

test('a disabled authenticated identity cannot use an active tenant membership', async () => {
  assert.equal((await shared.getChatAccess(tenant, uuid(17))).allowed, false);
});

for (const [title, room, uid, allowed] of [
  ['tenant owner', tenant, 11, true], ['tenant employee', tenant, 12, true],
  ['other clinic participant without tenant membership', tenant, 13, false],
  ['second global owner', globalRoom, 13, true],
  ['outsider owner', globalRoom, 14, false],
  ['global participant without any clinic', globalRoom, 16, false],
  ['removed global participant', globalRoom, 18, false],
  ['disabled global membership', globalRoom, 19, false],
  ['global employee cannot inherit a clinic owner role', globalRoom, 22, false],
  ['disabled superadmin', globalRoom, 20, false],
  ['active support superadmin without a clinic', globalRoom, 21, true],
  ['unjoined different global room', uuid(33), 11, false],
]) {
  test(`live access: ${title}`, async () => {
    assert.equal((await shared.getChatAccess(room, uuid(uid))).allowed, allowed);
  });
}

test('frozen tenant denies even an active superadmin', async () => {
  await inContext(`UPDATE public.accounts SET frozen=true WHERE id='${account}'`, async () => {
    const result = await shared.getChatAccess(tenant, uuid(21));
    assert.equal(result.allowed, false);
    assert.equal(result.accountFrozen, true);
  });
});

test('frozen sender clinic cannot grant global attachment access', async () => {
  await inContext(`UPDATE public.accounts SET frozen=true WHERE id='${account}'`, async () => {
    assert.equal((await shared.getChatAccess(globalRoom, uuid(11))).allowed, false);
    assert.equal((await shared.getChatAccess(globalRoom, uuid(13))).allowed, true);
  });
});

test('revoked role cannot retain an older global participant owner flag', async () => {
  await inContext(`UPDATE public.account_users SET role='employee' WHERE user_uid='${uuid(11)}'`, async () => {
    assert.equal((await shared.getChatAccess(globalRoom, uuid(11))).allowed, false);
  });
});

test('unknown conversation is denied', async () => {
  assert.equal((await shared.getChatAccess(uuid(999), uuid(11))).allowed, false);
});

test('private authority and ownership claim are not executable by a client SQL role', async () => {
  execute('CREATE ROLE elmam_chat_fixture_client NOLOGIN NOSUPERUSER NOINHERIT;');
  for (const query of [
    `SELECT * FROM public.chat_attachment_access_context('${globalRoom}','${uuid(11)}')`,
    `SELECT public.claim_chat_attachment_file('${uuid(94)}','chat-attachments','private.txt',NULL,'${globalRoom}','${uuid(42)}','${uuid(11)}')`,
  ]) {
    await inContext('SET LOCAL ROLE elmam_chat_fixture_client', async () => {
      assert.throws(() => rows(query), (error) => String(error.stderr).includes('permission denied for function'));
    });
  }
});

test('claim cannot invent a tenant for a global room or remove a tenant scope', async () => {
  assert.equal(await claim({accountId: account}), false);
  assert.equal(await claim({fileId: uuid(51), conversationId: tenant, messageId: uuid(41),
    fileName: `attachments/${tenant}/${uuid(41)}/fixture.txt`}), false);
});

test('claim is idempotent and cannot be transferred to another message or actor', async () => {
  assert.equal(await claim(), true);
  assert.equal(await claim(), true);
  assert.equal(await claim({messageId: uuid(43)}), false);
  assert.equal(await claim({uploadedByUserId: uuid(13)}), false);
  assert.equal(await claim({uploadedByUserId: uuid(21)}), false);
  assert.equal(rows(`SELECT count(*) AS n FROM public.chat_attachment_file_ownership WHERE file_id='${uuid(52)}'`)[0].n, 1);
});

test('ownership trigger rejects direct scope mismatch', () => {
  assert.throws(() => execute(`UPDATE public.chat_attachment_file_ownership SET account_id='${account}' WHERE file_id='${uuid(52)}';`),
    (error) => String(error.stderr).includes('chat attachment ownership scope mismatch'));
});

test('a changed membership is rechecked by the database claim', async () => {
  await inContext(`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(11)}'`, async () => {
    assert.equal(await claim({fileId: uuid(90), fileName: `attachments/${globalRoom}/${uuid(42)}/revoked.txt`}), false);
  });
});

test('a message tombstone denies a new file claim', async () => {
  await inContext(`UPDATE public.chat_messages SET deleted=true WHERE id='${uuid(42)}'`, async () => {
    assert.equal(await claim({fileId: uuid(91), fileName: `attachments/${globalRoom}/${uuid(42)}/deleted.txt`}), false);
  });
});

for (const action of ['resolve', 'sign']) {
  for (const uid of [11, 13]) {
    test(`actual SQL route: global owner ${uid} can ${action} the registered file`, async () => {
      assert.equal(await claim(), true);
      const response = await attempt(access, uuid(uid), {action, file_id: uuid(52)});
      assert.equal(response.statusCode, 200);
      assert.equal(response.body.file_id, uuid(52));
      assert.equal(storageCalls.length, action === 'sign' ? 1 : 0);
    });
  }
}

test('path-based lookup uses the same registered global scope', async () => {
  const response = await attempt(access, uuid(13), {action: 'resolve', bucket: 'chat-attachments',
    path: `attachments/${globalRoom}/${uuid(42)}/fixture.txt`});
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.file_id, uuid(52));
});

test('global outsider cannot resolve, sign or delete another conversation file', async () => {
  for (const action of ['resolve', 'sign', 'delete']) {
    const response = await attempt(access, uuid(14), {action, file_id: uuid(52)});
    assert.equal(response.statusCode, 403);
    assert.equal(storageCalls.length, 0);
  }
});

for (const flag of ['deleted', 'is_deleted']) {
  for (const action of ['resolve', 'sign']) {
    test(`deleted message attachment: ${flag} blocks a fresh ${action}`, async () => {
      assert.equal(await claim(), true);
      await inContext(`UPDATE public.chat_messages SET ${flag}=true WHERE id='${uuid(42)}'`, async () => {
        const response = await attempt(access, uuid(13), {action, file_id: uuid(52)});
        assert.equal(response.statusCode, 404);
        assert.equal(storageCalls.length, 0);
      });
    });
  }
}

test('uploader can still clean up a registered file after its message tombstone', async () => {
  assert.equal(await claim(), true);
  execute(`UPDATE public.chat_messages SET deleted=true WHERE id='${uuid(42)}';`);
  try {
    const response = await attempt(access, uuid(11), {action: 'delete', file_id: uuid(52)});
    assert.equal(response.statusCode, 200);
    assert.deepEqual(storageCalls.map((call) => call.method), ['DELETE']);
    assert.equal(rows(`SELECT count(*) AS n FROM public.chat_attachment_file_ownership WHERE file_id='${uuid(52)}'`)[0].n, 0);
  } finally {
    execute(`UPDATE public.chat_messages SET deleted=false WHERE id='${uuid(42)}';`);
    assert.equal(await claim(), true);
  }
});

test('global clinic owner role cannot delete the other uploader file', async () => {
  const response = await attempt(access, uuid(13), {action: 'delete', file_id: uuid(52)});
  assert.equal(response.statusCode, 403);
  assert.equal(response.body.error, 'delete_forbidden');
  assert.equal(storageCalls.length, 0);
});

test('uploader and active superadmin retain global delete authority', async () => {
  for (const uid of [11, 21]) {
    assert.equal(await claim(), true);
    const response = await attempt(access, uuid(uid), {action: 'delete', file_id: uuid(52)});
    assert.equal(response.statusCode, 200);
    assert.deepEqual(storageCalls.map((c) => c.method), ['DELETE']);
    assert.equal(rows(`SELECT count(*) AS n FROM public.chat_attachment_file_ownership WHERE file_id='${uuid(52)}'`)[0].n, 0);
  }
  // The Storage DELETE is mocked; only synthetic ownership rows changed locally.
  assert.equal(await claim(), true);
});

test('global clinic owner cannot upload onto the other sender message', async () => {
  const response = await attempt(upload, uuid(11), uploadBody(globalRoom, uuid(43)));
  assert.equal(response.statusCode, 403);
  assert.equal(storageCalls.length, 0);
});

test('global sender upload registers the actual file with null room scope', async () => {
  const response = await attempt(upload, uuid(11), uploadBody());
  assert.equal(response.statusCode, 201);
  assert.equal(storageCalls.length, 1);
  assert.equal(storageCalls[0].meta.metadata.account_id, null);
  const id = response.body.processedFiles[0].id;
  assert.equal(rows(`SELECT account_id FROM public.chat_attachment_file_ownership WHERE file_id='${id}'`)[0].account_id, null);
});

test('tenant admin upload onto a member message keeps its existing scope', async () => {
  const response = await attempt(upload, uuid(11), uploadBody(tenant, uuid(45)));
  assert.equal(response.statusCode, 201);
  assert.equal(storageCalls[0].meta.metadata.account_id, account);
});

test('revocation while Storage uploads prevents registration and targets only the new upload', async () => {
  revokeAfterUpload = true;
  try {
    const response = await attempt(upload, uuid(11), uploadBody());
    assert.equal(response.statusCode, 502);
    assert.equal(response.body.error, 'attachment_ownership_failed');
    assert.deepEqual(storageCalls.map((c) => c.method), ['POST', 'DELETE']);
    assert.equal(storageCalls[1].url.split('/').at(-1), storageCalls[0].id);
    assert.equal(rows(`SELECT count(*) AS n FROM public.chat_attachment_file_ownership WHERE file_id='${storageCalls[0].id}'`)[0].n, 0);
  } finally {
    revokeAfterUpload = false;
    context = '';
  }
});

test('quarantined registry cannot be bypassed via the historical attachment row', async () => {
  execute(`UPDATE public.chat_attachment_file_ownership SET security_state='quarantined' WHERE file_id='${uuid(55)}';`);
  const response = await attempt(access, uuid(11), {action: 'resolve', file_id: uuid(55)});
  assert.equal(response.statusCode, 404);
  assert.equal(storageCalls.length, 0);
  assert.equal(await claim({fileId: uuid(55), accountId: account, conversationId: tenant,
    messageId: uuid(45), uploadedByUserId: uuid(12), fileName: uuid(55)}), false,
  'A normal claim must not reactivate quarantined evidence');
});

test('a different Storage UUID cannot borrow ownership from an identical object name', async () => {
  assert.equal(await claim(), true);
  execute(`INSERT INTO storage.files(id,bucket_id,name) SELECT '${uuid(95)}',bucket_id,name FROM storage.files WHERE id='${uuid(52)}';`);
  const response = await attempt(access, uuid(13), {action: 'resolve', file_id: uuid(95)});
  assert.equal(response.statusCode, 404);
  assert.equal(storageCalls.length, 0);
});

test('concurrent uploaders cannot both claim the same immutable file identity', async () => {
  execute(`CREATE FUNCTION public.fixture_delay_chat_claim() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.file_id='${uuid(96)}'::uuid THEN PERFORM pg_sleep(0.5); END IF;
      RETURN NEW;
    END $$;
    CREATE TRIGGER fixture_delay_chat_claim BEFORE INSERT ON public.chat_attachment_file_ownership
      FOR EACH ROW EXECUTE FUNCTION public.fixture_delay_chat_claim();`);
  const concurrentClaim = (uid) => new Promise((resolve, reject) => {
    const query = `SELECT public.claim_chat_attachment_file('${uuid(96)}','chat-attachments',
      'attachments/${globalRoom}/${uuid(42)}/race.txt',NULL,'${globalRoom}','${uuid(42)}','${uuid(uid)}');`;
    execFile(process.env.ELMAM_CHAT_FIXTURE_PSQL,
      ['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-c',query],
      {encoding: 'utf8', timeout: 10000, env: {...process.env, PGCONNECT_TIMEOUT: '3'}},
      (error, stdout) => error ? reject(error) : resolve(stdout.trim()));
  });
  const results = await Promise.all([concurrentClaim(11), concurrentClaim(21)]);
  assert.deepEqual(results.sort(), ['conflict', 'linked']);
  assert.equal(rows(`SELECT count(*) AS n FROM public.chat_attachment_file_ownership WHERE file_id='${uuid(96)}'`)[0].n, 1);
});

test('unregistered global legacy files stay denied without guessed ownership', async () => {
  const response = await attempt(access, uuid(13), {action: 'resolve', file_id: uuid(53)});
  assert.equal(response.statusCode, 404);
});
