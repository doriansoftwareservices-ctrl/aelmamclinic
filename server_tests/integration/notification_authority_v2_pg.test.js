'use strict';

// Explicit opt-in: the bridge can reach only the owned network-none fixture.
// It never connects to Nhost or Google and never sends a notification.
const test = require('node:test');
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const {createInterface} = require('node:readline');
const {resolveNotificationAuthority, NotificationAuthorityUnavailable} =
  require('../../functions/_shared/notification_authority_v2');

const enabled = process.env.ELMAM_NOTIFICATION_AUTHORITY_FIXTURE === 'owned_pg14_20261023';
const docker = '/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe';
const container = 'elmam-remediation-pg14-v2-20261021';
const database = 'elmam_notification_delivery_v2_v1';
const uid = '21000000-0000-4000-8000-000000000003';
const other = '21000000-0000-4000-8000-000000000002';
const account = '11000000-0000-4000-8000-000000009901';
const token = '61000000-0000-4000-8000-000000000003';
const patient = '31000000-0000-4000-8000-000000009901';
const doctor = '51000000-0000-4000-8000-000000000003';
const installation = '81000000-0000-4000-8000-000000000003';
const rotatedToken = '61000000-0000-4000-8000-000000000013';
const owner = '21000000-0000-4000-8000-000000000001';
const admin = '21000000-0000-4000-8000-000000000007';
const adminToken = '61000000-0000-4000-8000-000000000007';
const adminInstallation = '81000000-0000-4000-8000-000000000007';
const room = '71000000-0000-4000-8000-000000000003';
const message = '91000000-0000-4000-8000-000000000003';
const plan = '91000000-0000-4000-8000-000000000007';
const seat = '91000000-0000-4000-8000-000000000008';
let bridge;
let serial = 0;
let bridgeError = '';
const pending = new Map();
const observed = [];

const python = `import sys,json,urllib.request,urllib.error
for line in sys.stdin:
 try:
  value=json.loads(line);actor=value.get('actor');headers={'Content-Type':'application/json','x-hasura-admin-secret':'elmam_fixture_admin_only'}
  if actor:
   assert actor['role'] in ['user','superadmin']
   headers.update({'x-hasura-role':actor['role'],'x-hasura-user-id':actor['uid']})
  req=urllib.request.Request('http://127.0.0.1:8085/v1/graphql',json.dumps({'query':value['document'],'variables':value['variables']}).encode(),headers)
  try:
   with urllib.request.urlopen(req,timeout=15) as response:status=response.status;body=json.load(response)
  except urllib.error.HTTPError as response:status=response.code;body=json.load(response)
  print(json.dumps({'id':value['id'],'status':status,'body':body}),flush=True)
 except Exception as error:print(json.dumps({'id':value.get('id'),'error':type(error).__name__}),flush=True)
`;

function query(request) {
  observed.push(request);
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => {
      pending.delete(id);reject(new Error('owned_fixture_query_timeout'));
    }, 25000);
    pending.set(id, {resolve, reject, timer});
    bridge.stdin.write(JSON.stringify({id, ...request}) + '\n');
  });
}

function sql(statement) {
  return new Promise((resolve, reject) => {
    const child = spawn(docker, ['exec', '-i', container, 'psql', '-U', 'postgres',
      '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database]);
    let error = '';
    child.stderr.on('data', value => {error += value;});
    child.stdout.resume();
    const timer = setTimeout(() => {child.kill();reject(new Error('owned_SQL_timeout'));}, 20000);
    child.on('error', reject);
    child.on('exit', code => {
      clearTimeout(timer);
      if (code) reject(new Error('owned_fixture_SQL_failed:' + error));
      else resolve();
    });
    child.stdin.end("BEGIN;DO $$ BEGIN IF current_database()<>'" + database +
      "' THEN RAISE EXCEPTION 'owned_fixture_only';END IF;END $$;" + statement + ';COMMIT;');
  });
}

function target() {
  return {user_uid: uid, token_id: token, installation_id: installation, delivery_event: {
    event_type: 'new_patient', source_id: patient, account_id: account}};
}

test.before(() => {
  if (!enabled) return;
  bridge = spawn(docker, ['run', '--rm', '-i', '--network', 'container:' + container,
    '--entrypoint', 'python3', 'public.ecr.aws/supabase/postgres:17.4.1.069', '-u', '-c', python]);
  bridge.stderr.on('data', value => {bridgeError += value;});
  createInterface({input: bridge.stdout}).on('line', line => {
    const reply = JSON.parse(line);
    const wait = pending.get(reply.id);
    if (!wait) return;
    pending.delete(reply.id);clearTimeout(wait.timer);
    if (reply.error || reply.status !== 200 || reply.body.errors) {
      wait.reject(new Error('owned_fixture_graphql_unavailable'));
    } else wait.resolve(reply.body.data);
  });
});
test.after(async () => {
  if (!bridge) return;
  bridge.stdin.end();
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {bridge.kill();reject(new Error('owned_bridge_cleanup_timeout'));}, 20000);
    bridge.on('exit', code => {
      clearTimeout(timer);
      if (code) reject(new Error('owned_bridge_failed:' + bridgeError));else resolve();
    });
  });
});

test('actual source permits the linked doctor under user permissions despite forged token role', {skip: !enabled}, async () => {
  const result = await resolveNotificationAuthority(target(), {query});
  assert.equal(result.allowed, true);
  assert.equal(result.sourceId, patient);
  assert.deepEqual(observed.find(r => r.document.includes('query NotificationPatient')).actor,
    {uid, role: 'user'});
});

for (const [name, mutation, restore, reason] of [
  ['revoked membership', `UPDATE public.account_users SET disabled=true WHERE user_uid='${uid}' AND account_id='${account}'`,
    `UPDATE public.account_users SET disabled=false WHERE user_uid='${uid}' AND account_id='${account}'`, 'source_not_visible'],
  ['frozen clinic', `UPDATE public.accounts SET frozen=true WHERE id='${account}'`,
    `UPDATE public.accounts SET frozen=false WHERE id='${account}'`, 'source_not_visible'],
  ['revoked patient feature', `UPDATE public.account_feature_permissions SET allow_all=false,allowed_features=ARRAY[]::text[] WHERE user_uid='${uid}' AND account_id='${account}'`,
    `UPDATE public.account_feature_permissions SET allow_all=false,allowed_features=ARRAY['patients.list','patients.new']::text[] WHERE user_uid='${uid}' AND account_id='${account}'`, 'source_not_visible'],
  ['disabled Auth', `UPDATE auth.users SET disabled=true WHERE id='${uid}'`,
    `UPDATE auth.users SET disabled=false WHERE id='${uid}'`, 'recipient_disabled'],
  ['rebound token', `UPDATE public.push_device_tokens SET user_uid='${other}' WHERE id='${token}'`,
    `UPDATE public.push_device_tokens SET user_uid='${uid}' WHERE id='${token}'`, 'registration_unavailable'],
  ['changed registration clinic', `UPDATE public.push_device_tokens SET account_id='11000000-0000-4000-8000-000000009902' WHERE id='${token}'`,
    `UPDATE public.push_device_tokens SET account_id='${account}' WHERE id='${token}'`, 'registration_scope_changed'],
  ['changed patient assignment', `UPDATE public.patients SET doctor_id=NULL WHERE id='${patient}'`,
    `UPDATE public.patients SET doctor_id='${doctor}' WHERE id='${patient}'`, 'doctor_not_assigned'],
]) {
  test('actual ' + name + ' is checked again before delivery', {skip: !enabled}, async () => {
    try {
      await sql(mutation);
      assert.deepEqual(await resolveNotificationAuthority(target(), {query}), {allowed: false, reason});
    } finally {await sql(restore);}
  });
}

test('real token rotation retains the captured installation and resolves its new transport token', {skip: !enabled}, async () => {
  try {
    await sql(`UPDATE public.push_device_tokens SET is_active=false WHERE id='${token}';
      INSERT INTO public.push_device_tokens(id,user_uid,account_id,platform,token,installation_id,delivery_protocol)
      VALUES('${rotatedToken}','${uid}','${account}','android','synthetic_actual_rotation','${installation}',2)`);
    const result = await resolveNotificationAuthority(target(), {query});
    assert.equal(result.allowed, true);
    assert.equal(result.registrationId, rotatedToken);
    assert.equal(result.transportToken, 'synthetic_actual_rotation');
    assert.equal(target().token_id, token);
  } finally {
    await sql(`DELETE FROM public.push_device_tokens WHERE id='${rotatedToken}';
      UPDATE public.push_device_tokens SET is_active=true WHERE id='${token}'`);
  }
});

test('prepare real chat and request sources without webhook or dispatcher activation', {skip: !enabled}, async () => {
  await sql(`
    INSERT INTO public.chat_conversations(id,account_id,created_by,is_group)
      VALUES('${room}','${account}','${owner}',true) ON CONFLICT DO NOTHING;
    INSERT INTO public.chat_participants(conversation_id,user_uid,account_id,role)
      VALUES('${room}','${uid}','${account}','member'),('${room}','${owner}','${account}','owner') ON CONFLICT DO NOTHING;
    SELECT set_config('hasura.user','{"x-hasura-user-id":"${owner}","x-hasura-role":"user"}',true);
    INSERT INTO public.chat_messages(id,conversation_id,account_id,sender_uid,body)
      VALUES('${message}','${room}','${account}','${owner}','synthetic only') ON CONFLICT DO NOTHING;
    SELECT set_config('hasura.user','{}',true);
    INSERT INTO public.subscription_plans(code,name,price_usd,duration_months,is_active)
      VALUES('notification_authority_fixture','synthetic only',0,1,true) ON CONFLICT DO NOTHING;
    INSERT INTO public.subscription_requests(id,account_id,user_uid,plan_code)
      VALUES('${plan}','${account}','${owner}','notification_authority_fixture') ON CONFLICT DO NOTHING;
    INSERT INTO public.employee_seat_requests(id,account_id,requested_by_uid,employee_email,status)
      VALUES('${seat}','${account}','${owner}','synthetic@example.invalid','submitted') ON CONFLICT DO NOTHING;
    INSERT INTO public.push_device_tokens(id,user_uid,platform,token,installation_id,delivery_protocol)
      VALUES('${adminToken}','${admin}','android','synthetic_admin_authority','${adminInstallation}',2) ON CONFLICT DO NOTHING
  `);
});

function chatTarget() {
  return {...target(), delivery_event: {event_type: 'chat_message', source_id: message, account_id: account}};
}
test('real chat source is read as its employee participant', {skip: !enabled}, async () => {
  const result = await resolveNotificationAuthority(chatTarget(), {query});
  assert.equal(result.allowed, true);
  assert.equal(result.conversationId, room);
});
for (const flag of ['muted', 'archived', 'blocked']) {
  test('real participant ' + flag + ' suppresses a queued chat alert', {skip: !enabled}, async () => {
    const actor = `SELECT set_config('hasura.user','{"x-hasura-user-id":"${uid}","x-hasura-role":"user"}',true);`;
    try {
      await sql(actor + `UPDATE public.chat_participants SET ${flag}=true WHERE conversation_id='${room}' AND user_uid='${uid}'`);
      assert.deepEqual(await resolveNotificationAuthority(chatTarget(), {query}),
        {allowed: false, reason: 'participant_notifications_disabled'});
    } finally {
      await sql(actor + `UPDATE public.chat_participants SET ${flag}=false WHERE conversation_id='${room}' AND user_uid='${uid}'`);
    }
  });
}
for (const [kind, source] of [['plan_request', plan], ['seat_request', seat]]) {
  test('real active system admin can read its ' + kind + ' source', {skip: !enabled}, async () => {
    const destination = {user_uid: admin, token_id: adminToken, installation_id: adminInstallation,
      delivery_event: {event_type: kind, source_id: source, account_id: account}};
    assert.equal((await resolveNotificationAuthority(destination, {query})).allowed, true);
  });
}
test('revoked real system admin cannot inherit its old queued plan alert', {skip: !enabled}, async () => {
  try {
    await sql(`UPDATE public.super_admins SET disabled=true WHERE user_uid='${admin}'`);
    const destination = {user_uid: admin, token_id: adminToken, installation_id: adminInstallation,
      delivery_event: {event_type: 'plan_request', source_id: plan, account_id: account}};
    assert.deepEqual(await resolveNotificationAuthority(destination, {query}),
      {allowed: false, reason: 'active_superadmin_required'});
  } finally {await sql(`UPDATE public.super_admins SET disabled=false WHERE user_uid='${admin}'`);}
});

test('real schema errors remain retryable without changing to an admin source read', {skip: !enabled}, async () => {
  const adapter = request => query(request.actor
    ? {...request, document: 'query BrokenSource {field_that_does_not_exist}'} : request);
  await assert.rejects(resolveNotificationAuthority(target(), {query: adapter}), NotificationAuthorityUnavailable);
});
test('source is still available after all fixture restorations', {skip: !enabled}, async () => {
  assert.equal((await resolveNotificationAuthority(target(), {query})).allowed, true);
});
