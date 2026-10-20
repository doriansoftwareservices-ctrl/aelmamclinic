'use strict';
const assert = require('node:assert/strict');
const {execFileSync, spawn} = require('node:child_process');
const test = require('node:test');

assert.equal(process.env.PGHOST, '127.0.0.1');
assert.equal(process.env.PGHOSTADDR, '127.0.0.1');
assert.equal(process.env.PGUSER, 'elmam_owner_fixture');
assert.match(process.env.PGDATABASE || '', /^elmam_owner_fixture_[a-z0-9_]+$/);
const psql = process.env.ELMAM_OWNER_PSQL;
assert.match(psql || '', /PostgreSQL[\\/]18\.6[\\/]bin[\\/]psql\.exe$/i);
const args = ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'];
const quote = value => value == null ? 'NULL' : `'${String(value).replaceAll("'", "''")}'`;
let serial = 100;
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const profile = ['عيادة اختبار', 'مدينة', 'شارع', 'بجوار', "Synthetic clinic's name",
  'City', 'Street', 'Near', '000000000', '000000001'];
function execute(sql) {
  return execFileSync(psql, args, {input: sql, encoding: 'utf8', timeout: 12000,
    env: {...process.env, PGOPTIONS: '-c statement_timeout=7000'}, stdio: ['pipe','pipe','pipe']}).trim();
}
function query(sql) {
  return JSON.parse(execute(`SELECT coalesce(json_agg(row_to_json(r)),'[]'::json)::text FROM (${sql}) r;`));
}
assert.deepEqual(query('SELECT value FROM public.elmam_owner_fixture_marker'),
  [{value: 'local_owner_onboarding_20261020'}]);
function seed({disabled = false, role, membershipDisabled = false} = {}) {
  const uid = uuid(++serial);
  execute(`INSERT INTO auth.users(id,email,disabled) VALUES(${quote(uid)},'fixture@example.invalid',${disabled});`);
  let account;
  if (role) {
    account = uuid(++serial);
    execute(`INSERT INTO public.accounts(id,name) VALUES(${quote(account)},'Existing synthetic');
      INSERT INTO public.account_users VALUES(${quote(uid)},${quote(account)},${quote(role)},${membershipDisabled},now());
      INSERT INTO public.account_subscriptions(account_id,plan_code,status) VALUES(${quote(account)},'paid_fixture','active');
      INSERT INTO public.account_feature_permissions VALUES(${quote(account)},'paid_fixture');`);
  }
  return {uid, account};
}
function callSql(uid, values = profile, extra = '') {
  const session = JSON.stringify(uid ? {'x-hasura-user-id': uid, 'x-hasura-role':'user'} : {});
  return `BEGIN; SET LOCAL "hasura.user"=${quote(session)}; ${extra}
    SELECT id::text FROM public.self_create_account(${values.map(quote).join(',')}); COMMIT;`;
}
function create(uid, values, extra) { return execute(callSql(uid, values, extra)).split(/\r?\n/).at(-1); }
function image() {
  return JSON.stringify(query(`SELECT jsonb_build_object(
    'accounts',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.accounts r),
    'users',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM auth.users r),
    'memberships',(SELECT jsonb_agg(to_jsonb(r) ORDER BY user_uid,account_id) FROM public.account_users r),
    'profiles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.profiles r),
    'subscriptions',(SELECT jsonb_agg(to_jsonb(r) ORDER BY account_id) FROM public.account_subscriptions r),
    'permissions',(SELECT jsonb_agg(to_jsonb(r) ORDER BY account_id) FROM public.account_feature_permissions r)
    ) AS state`));
}
function denied(uid, expected, values = profile, extra = '') {
  const before = image();
  assert.throws(() => create(uid, values, extra), error => String(error.stderr).includes(expected));
  assert.equal(image(), before, 'a rejected create must preserve every existing row');
}

test('real SQL creates one complete bilingual clinic, membership, profile, free plan and claims', () => {
  const {uid} = seed();
  const id = create(uid);
  assert.match(id, /^[0-9a-f-]{36}$/);
  assert.deepEqual(query(`SELECT name,clinic_name_en,phone2 FROM public.accounts WHERE id=${quote(id)}`),
    [{name: profile[0], clinic_name_en: profile[4], phone2: profile[9]}]);
  assert.deepEqual(query(`SELECT role,disabled FROM public.account_users WHERE user_uid=${quote(uid)}`), [{role:'owner',disabled:false}]);
  assert.deepEqual(query(`SELECT account_id,role FROM public.profiles WHERE id=${quote(uid)}`), [{account_id:id,role:'owner'}]);
  assert.deepEqual(query(`SELECT plan_code,status FROM public.account_subscriptions WHERE account_id=${quote(id)}`), [{plan_code:'free',status:'active'}]);
  assert.deepEqual(query(`SELECT metadata FROM auth.users WHERE id=${quote(uid)}`), [{metadata:{role:'owner',account_id:id}}]);
});
for (const role of ['employee', 'doctor', 'member', '']) {
  test(`real SQL rejects linked ${role || 'unknown'} role without creating an owner clinic`, () => {
    const {uid} = seed({role: role || ' '});
    denied(uid, 'already linked to an account');
  });
}
for (const role of ['owner','admin']) {
  test(`real SQL ${role} replay returns its original paid clinic without changing a row`, () => {
    const {uid,account} = seed({role});
    const before = image();
    assert.equal(create(uid), account);
    assert.equal(image(), before);
  });
}
test('real SQL disabled membership cannot create a second clinic', () => {
  denied(seed({role:'owner',membershipDisabled:true}).uid, 'user_disabled');
});
test('real SQL disabled Auth identity cannot create a clinic with a retained token', () => {
  denied(seed({disabled:true}).uid, 'user_disabled');
});
test('real SQL absent identity cannot create a clinic', () => { denied(null, 'unauthenticated'); });
test('real SQL nonexistent Auth identity cannot create a clinic', () => { denied(uuid(999999), 'unauthenticated'); });
for (let field = 0; field < 9; field++) {
  test(`real SQL required profile argument ${field + 1} rolls back without side effects`, () => {
    const {uid} = seed();
    const values = [...profile]; values[field] = ' ';
    denied(uid, 'required', values);
  });
}
test('real SQL failed plan seeding rolls back clinic, membership, profile and claims together', () => {
  denied(seed().uid, 'fixture_plan_failure', profile, 'SET LOCAL "fixture.fail_plan"=true;');
});
test('real SQL optional second phone keeps its nullable contract', () => {
  const {uid} = seed();
  const id = create(uid, [...profile.slice(0,9), ' ']);
  assert.deepEqual(query(`SELECT phone2 FROM public.accounts WHERE id=${quote(id)}`), [{phone2:null}]);
});

function child(sql, name, keepOpen = false) {
  const processHandle = spawn(psql, args, {env:{...process.env,
    PGAPPNAME:name,PGOPTIONS:'-c statement_timeout=7000'}, stdio:['pipe','pipe','pipe']});
  let output = '', error = '';
  processHandle.stdout.setEncoding('utf8').on('data', text => { output += text; });
  processHandle.stderr.setEncoding('utf8').on('data', text => { error += text; });
  const done = new Promise((resolve,reject) => {
    processHandle.on('error',reject);
    processHandle.on('close',code => code === 0 ? resolve(output.trim()) : reject(Error(`fixture child failed ${code}: ${error}`)));
  });
  // Observe any early failure immediately, even while waiting for the barrier.
  done.catch(() => {});
  if (keepOpen) processHandle.stdin.write(sql); else processHandle.stdin.end(sql);
  return {processHandle,done,get output(){return output;}};
}
async function until(condition) {
  const end = Date.now()+5000;
  while (!condition()) {
    assert.ok(Date.now()<end, 'owned local barrier did not converge');
    await new Promise(resolve => setTimeout(resolve,25));
  }
}
test('real SQL two simultaneous creates return one clinic and one set of memberships/plan', async () => {
  const {uid} = seed();
  const name = `owner_fixture_${uid.slice(-5)}`;
  const barrier = child("BEGIN; SELECT pg_advisory_xact_lock(202610200010); SELECT 'barrier-ready';\n",`${name}_barrier`,true);
  let left, right;
  try {
    await until(() => barrier.output.includes('barrier-ready'));
    const sql = callSql(uid,profile,'SET LOCAL "fixture.owner_barrier"=true;');
    left = child(sql,`${name}_left`); right = child(sql,`${name}_right`);
    await until(() => query(`SELECT count(*)::integer AS n FROM pg_stat_activity WHERE application_name IN (${quote(name+'_left')},${quote(name+'_right')}) AND wait_event_type='Lock'`)[0].n === 2);
    barrier.processHandle.stdin.end('COMMIT;\n');
    const ids = await Promise.all([left.done,right.done]);
    assert.equal(new Set(ids).size,1,'concurrent retries must return the original clinic');
    const memberships = query(`SELECT account_id,role FROM public.account_users WHERE user_uid=${quote(uid)}`);
    assert.deepEqual(memberships,[{account_id:ids[0],role:'owner'}]);
    assert.deepEqual(query(`SELECT count(*)::integer AS n FROM public.account_subscriptions WHERE account_id=${quote(ids[0])}`),[{n:1}]);
  } finally {
    if (!barrier.processHandle.stdin.destroyed) barrier.processHandle.stdin.end('ROLLBACK;\n');
    await Promise.allSettled([barrier.done,...[left,right].filter(Boolean).map(value=>value.done)]);
  }
});

test('real SQL identity serialization needs no new UPDATE grant on Auth users', () => {
  const {uid} = seed();
  execute(`DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='elmam_owner_definer_fixture') THEN
    CREATE ROLE elmam_owner_definer_fixture NOLOGIN; END IF; END $$;
    GRANT USAGE,CREATE ON SCHEMA public TO elmam_owner_definer_fixture;
    GRANT USAGE ON SCHEMA auth TO elmam_owner_definer_fixture;
    GRANT SELECT ON auth.users TO elmam_owner_definer_fixture;
    GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO elmam_owner_definer_fixture;
    ALTER FUNCTION public.self_create_account(text,text,text,text,text,text,text,text,text,text)
      OWNER TO elmam_owner_definer_fixture;`);
  try {
    assert.equal(query("SELECT has_table_privilege('elmam_owner_definer_fixture','auth.users','UPDATE') AS allowed")[0].allowed,false);
    assert.match(create(uid), /^[0-9a-f-]{36}$/);
  } finally {
    execute('ALTER FUNCTION public.self_create_account(text,text,text,text,text,text,text,text,text,text) OWNER TO elmam_owner_fixture;');
  }
});
