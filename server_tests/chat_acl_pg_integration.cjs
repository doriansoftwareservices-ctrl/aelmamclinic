'use strict';
const assert = require('node:assert/strict');
const {execFileSync,spawn} = require('node:child_process');
const fs = require('node:fs');
const test = require('node:test');

// Integration is opt-in through the fresh-cluster runner, outside *.test.js.
assert.equal(process.env.PGHOST, '127.0.0.1');
assert.equal(process.env.PGHOSTADDR, '127.0.0.1');
assert.equal(process.env.PGUSER, 'elmam_chat_acl_fixture');
assert.match(process.env.PGDATABASE || '', /^elmam_chat_acl_fixture_[a-z0-9_]+$/);
assert.match(process.env.ELMAM_CHAT_ACL_PSQL || '', /PostgreSQL[\\/]18\.6[\\/]bin[\\/]psql\.exe$/i);
assert.ok(fs.existsSync(process.env.ELMAM_CHAT_ACL_PSQL));
assert.ok(Number(process.env.PGPORT) > 1024);
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const tenant = uuid(31);
const globalRoom = uuid(32);
const client = 'elmam_chat_acl_client';

function psql(input) {
  return execFileSync(process.env.ELMAM_CHAT_ACL_PSQL,
    ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], {
      input, encoding: 'utf8', timeout: 10000,
      env: {...process.env, PGCONNECT_TIMEOUT: '3', PGOPTIONS: '-c statement_timeout=5000'},
      stdio: ['pipe', 'pipe', 'pipe'],
    });
}
function psqlAsync(input) {
  return new Promise((resolve,reject)=>{
    const child=spawn(process.env.ELMAM_CHAT_ACL_PSQL,
      ['-X','-q','-A','-t','-v','ON_ERROR_STOP=1'],{
        env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=5000'},
        stdio:['pipe','pipe','pipe'],
      });
    let output='',stderr='';
    const timeout=setTimeout(()=>child.kill(),10000);
    child.stdout.on('data',chunk=>{output+=chunk;});
    child.stderr.on('data',chunk=>{stderr+=chunk;});
    child.once('error',error=>{clearTimeout(timeout);reject(error);});
    child.once('exit',code=>{
      clearTimeout(timeout);
      if(code===0)resolve(output);
      else reject(Object.assign(new Error(`Owned SQL process exit ${code}: ${stderr}`),{stderr}));
    });
    child.stdin.end(input);
  });
}
function query(sql, {actor = 11, setup = '', change = '', role = client, claims = null} = {}) {
  const session = claims || {'x-hasura-user-id': uuid(actor), 'x-hasura-role': 'user'};
  const quoted = JSON.stringify(session).replaceAll("'", "''");
  const wrapped = `SELECT coalesce(json_agg(row_to_json(fixture_rows)), '[]'::json)::text FROM (${sql}) fixture_rows`;
  const output = psql(`BEGIN; ${setup}; SET LOCAL "hasura.user"='${quoted}';
    ${role ? `SET LOCAL ROLE ${role};` : ''} ${change}; ${wrapped}; ROLLBACK;`);
  return JSON.parse(output.trim());
}
function denied(sql, options, message) {
  assert.throws(() => query('SELECT true AS survived', {...options, change: sql}),
    (error) => {assert.ok(String(error.stderr).includes(message),String(error.stderr));return true;}, message);
}
function authority(room, actor, setup = '') {
  return query(`SELECT can_read,can_self_update,can_bootstrap,is_superadmin
    FROM public.chat_current_access WHERE conversation_id='${room}' AND user_uid='${uuid(actor)}'`,
  {actor, setup})[0] || {can_read: false, can_self_update: false, can_bootstrap: false, is_superadmin: false};
}

assert.equal(query('SELECT value FROM public.elmam_chat_acl_fixture_marker', {role: ''})[0].value,
  'local_chat_acl_scope_20261019');
psql(`GRANT SELECT ON public.chat_scope_authority,public.chat_current_access,
  public.active_superadmin_identity,public.v_chat_last_message,
  public.v_chat_conversations_for_me,public.v_chat_reads_for_me,
  public.v_chat_typing_active,public.v_chat_messages_with_attachments
  TO ${client};`);

test('SQL client is neither table owner, superuser nor BYPASSRLS', () => {
  assert.deepEqual(query(`SELECT r.rolsuper,r.rolbypassrls,
    current_user=(SELECT tableowner FROM pg_tables WHERE schemaname='public' AND tablename='chat_participants') AS owns_table
    FROM pg_roles r WHERE rolname=current_user`)[0],
  {rolsuper: false, rolbypassrls: false, owns_table: false});
});

for (const [label, room, actor, allowed] of [
  ['tenant owner', tenant, 11, true], ['tenant employee', tenant, 12, true],
  ['foreign clinic participant', tenant, 13, false], ['disabled Auth identity', tenant, 17, false],
  ['global owner A', globalRoom, 11, true], ['global owner B', globalRoom, 13, true],
  ['global employee with old participant role', globalRoom, 12, false],
  ['global participant without current clinic', globalRoom, 16, false],
  ['removed global participant', globalRoom, 18, false],
  ['disabled clinic membership', globalRoom, 19, false],
  ['disabled superadmin registry', globalRoom, 20, false],
  ['global employee from other clinic', globalRoom, 22, false],
  ['outsider owner', globalRoom, 14, false],
  ['active superadmin without clinic', globalRoom, 21, true],
  ['assigned active support in its existing support room', uuid(35), 25, true],
  ['inactive support assignment', uuid(35), 26, false],
  ['active support without participation in other direct room', globalRoom, 25, false],
  ['active support participant in a group is not global scope', tenant, 25, false],
]) {
  test(`current authority: ${label}`, () => assert.equal(authority(room, actor).can_read, allowed));
}

for (const [label, setup, actor, room] of [
  ['membership revoked', `UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(12)}'`, 12, tenant],
  ['clinic frozen', `UPDATE public.accounts SET frozen=true WHERE id='${uuid(1)}'`, 12, tenant],
  ['global owner demoted', `UPDATE public.account_users SET role='employee' WHERE user_uid='${uuid(11)}'`, 11, globalRoom],
  ['global owner clinic frozen', `UPDATE public.accounts SET frozen=true WHERE id='${uuid(1)}'`, 11, globalRoom],
  ['Auth disabled', `UPDATE auth.users SET disabled=true WHERE id='${uuid(11)}'`, 11, tenant],
]) {
  test(`revocation removes actual SQL reads and previews: ${label}`, () => {
    assert.equal(authority(room, actor, setup).can_read, false);
    for (const [view, column] of [
      ['chat_conversations', 'id'], ['chat_messages', 'conversation_id'],
      ['chat_participants', 'conversation_id'], ['chat_reads', 'conversation_id'],
      ['v_chat_last_message', 'conversation_id'], ['v_chat_conversations_for_me', 'id'],
      ['v_chat_reads_for_me', 'conversation_id'], ['v_chat_typing_active', 'conversation_id'],
      ['v_chat_messages_with_attachments', 'conversation_id'],
    ]) {
      assert.deepEqual(query(`SELECT ${column} FROM public.${view} WHERE ${column}='${room}'`, {actor, setup}), [], view);
    }
  });
}

test('frozen tenant also denies active superadmin', () => {
  assert.equal(authority(tenant, 21, `UPDATE public.accounts SET frozen=true WHERE id='${uuid(1)}'`).can_read, false);
});
test('global owner demotion does not revoke the other current owner', () => {
  assert.equal(authority(globalRoom, 13,
    `UPDATE public.account_users SET role='employee' WHERE user_uid='${uuid(11)}'`).can_read, true);
});
test('support assignment revocation immediately removes existing support-room reads', () => {
  const setup=`UPDATE public.chat_support_agents SET is_active=false WHERE user_uid='${uuid(25)}'`;
  assert.equal(authority(uuid(35),25,setup).can_read,false);
  assert.deepEqual(query(`SELECT conversation_id FROM public.v_chat_last_message
    WHERE conversation_id='${uuid(35)}'`,{actor:25,setup}),[]);
});
test('unjoined creator is bootstrap eligible without room read authority', () => {
  const result = authority(uuid(34), 11);
  assert.equal(result.can_bootstrap, true);
  assert.equal(result.can_read, false);
});

for (const [field, value] of [
  ['conversation_id', `'${uuid(34)}'`], ['account_id', `'${uuid(2)}'`], ['user_uid', `'${uuid(14)}'`],
]) {
  test(`participant SQL identity guard rejects ${field} retarget`, () => {
    denied(`UPDATE public.chat_participants SET ${field}=${value}
      WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 12},
    'chat_participant_identity_is_immutable');
  });
}
test('participant SQL trigger rejects self role promotion', () => {
  denied(`UPDATE public.chat_participants SET role='owner'
    WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 12},
  'chat_participant_role_change_forbidden');
});
test('foreign-room insert cannot use the actor own clinic', () => {
  denied(`INSERT INTO public.chat_participants(conversation_id,user_uid,account_id,role)
    VALUES ('${uuid(33)}','${uuid(11)}','${uuid(1)}','member')`, {actor: 11},
  'chat_participant_scope_mismatch');
});
test('noncreator cannot directly self join a room in their valid clinic', () => {
  denied(`INSERT INTO public.chat_participants(conversation_id,user_uid,account_id,role)
    VALUES ('${uuid(34)}','${uuid(12)}','${uuid(1)}','member')`, {actor: 12},
  'chat_participant_direct_self_join_forbidden');
});
test('creator direct bootstrap preserves the current createGroup contract', () => {
  const result = query(`SELECT role,personal_hidden FROM public.chat_participants
    WHERE conversation_id='${uuid(34)}' AND user_uid='${uuid(11)}'`, {actor: 11,
    change: `INSERT INTO public.chat_participants(conversation_id,user_uid,account_id,role,email,joined_at)
      VALUES ('${uuid(34)}','${uuid(11)}','${uuid(1)}','owner','creator@example.invalid',now())
      ON CONFLICT (conversation_id,user_uid) DO UPDATE SET email=EXCLUDED.email,joined_at=EXCLUDED.joined_at`});
  assert.deepEqual(result, [{role: 'owner', personal_hidden: false}]);
});

test('ordinary personal hide and unhide preserve access without reviving removed members', () => {
  const result = query(`SELECT is_deleted,personal_hidden FROM public.chat_participants
    WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 12,
    change: `UPDATE public.chat_participants SET is_deleted=true,deleted_at=now()
      WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}';
      UPDATE public.chat_participants SET is_deleted=false,deleted_at=NULL
      WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`});
  assert.deepEqual(result, [{is_deleted: false, personal_hidden: false}]);
});
test('old removed participant has no self-service authority and cannot unhide', () => {
  assert.equal(authority(tenant, 24).can_self_update, false);
  denied(`UPDATE public.chat_participants SET is_deleted=false,deleted_at=NULL
    WHERE conversation_id='${tenant}' AND user_uid='${uuid(24)}'`, {actor: 24,role: ''},
  'chat_removed_participant_is_not_self_service');
});
test('owner RPC removal keeps a revoked member separate from personal hide', () => {
  const rows = query(`SELECT is_deleted,personal_hidden FROM public.chat_participants
    WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 11,
    change: `DO $$ BEGIN PERFORM * FROM public.chat_group_remove_member('${tenant}','${uuid(12)}'); END $$`});
  assert.deepEqual(rows, [{is_deleted: true, personal_hidden: false}]);
});

for (const table of ['chat_reads', 'chat_typing']) {
  test(`${table} SQL guard rejects identity retarget`, () => {
    denied(`UPDATE public.${table} SET conversation_id='${uuid(34)}'
      WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 12},
    'chat_state_identity_is_immutable');
  });
  test(`${table} SQL writes reject current membership revocation`, () => {
    denied(`UPDATE public.${table} SET ${table === 'chat_reads' ? 'last_read_at' : 'updated_at'}=now()
      WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 12,
      setup: `UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(12)}'`,role: ''},
    'chat_current_authority_required');
  });
}
test('read cursor cannot borrow a message from another room', () => {
  denied(`UPDATE public.chat_reads SET last_read_message_id='${uuid(42)}'
    WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'`, {actor: 12},
  'chat_read_cursor_scope_mismatch');
});
test('private helpers cannot be invoked by an ordinary SQL role', () => {
  for (const name of ['chat_actor_has_scope', 'chat_actor_can_read', 'chat_lock_actor_scope','chat_attachment_access_context']) {
    assert.throws(() => query(`SELECT public.${name}('${tenant}','${uuid(11)}') AS value`),
      (error) => String(error.stderr).includes(`permission denied for function ${name}`));
  }
});

for (const [label,room,actor,allowed] of [
  ['tenant owner',tenant,11,true],['tenant employee',tenant,12,true],
  ['global owner',globalRoom,13,true],['global employee',globalRoom,12,false],
  ['active assigned support',uuid(35),25,true],['inactive support',uuid(35),26,false],
]) {
  test(`attachment SQL context shares current authority: ${label}`,()=>{
    const row=query(`SELECT * FROM public.chat_attachment_access_context('${room}','${uuid(actor)}')`,{role:''})[0];
    assert.equal(row.allowed,allowed);
    if(actor===25) assert.equal(row.participant_role,'support');
  });
}
for(const [label,actor,room,message,account,expected] of [
  ['tenant sender',11,tenant,41,uuid(1),'linked'],
  ['global sender',11,globalRoom,42,null,'linked'],
  ['global other owner cannot claim another sender',13,globalRoom,42,null,'forbidden'],
  ['support cannot claim clinic sender file as admin',25,uuid(35),44,uuid(1),'forbidden'],
  ['support sender can claim its own file',25,uuid(35),45,uuid(1),'linked'],
  ['active superadmin',21,globalRoom,42,null,'linked'],
]) {
  test(`attachment ownership regression: ${label}`,()=>{
    const scope=account?`'${account}'`:'NULL';
    const rows=query(`SELECT public.claim_chat_attachment_file('${uuid(91)}','chat-attachments',
      'attachments/${room}/${uuid(message)}/new-fixture.txt',${scope},'${room}','${uuid(message)}','${uuid(actor)}') AS result`,{role:''});
    assert.equal(rows[0].result,expected);
  });
}
test('claim rejects membership revoked after initial attachment access',()=>{
  const result=query(`SELECT public.claim_chat_attachment_file('${uuid(91)}','chat-attachments',
    'revoked-fixture.txt','${uuid(1)}','${tenant}','${uuid(41)}','${uuid(11)}') AS result`,
  {role:'',setup:`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(11)}'`})[0];
  assert.equal(result.result,'forbidden');
});

test('waiting chat write rechecks membership committed during its lock wait',async()=>{
  const child=spawn(process.env.ELMAM_CHAT_ACL_PSQL,['-X','-q','-A','-t','-v','ON_ERROR_STOP=1'],{
    env:{...process.env,PGCONNECT_TIMEOUT:'3',PGOPTIONS:'-c statement_timeout=5000'},
    stdio:['pipe','pipe','pipe'],
  });
  let output='';let stderr='';let signal;
  const acquired=new Promise(resolve=>{signal=resolve;});
  child.stdout.on('data',chunk=>{output+=chunk;if(output.includes('fixture-revocation-lock'))signal();});
  child.stderr.on('data',chunk=>{stderr+=chunk;});
  const completion=new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('exit',code=>code===0?resolve():reject(new Error(`Owned revoker failed: ${stderr}`)));
  });
  child.stdin.end(`BEGIN; SELECT user_uid FROM public.account_users
    WHERE account_id='${uuid(1)}' AND user_uid='${uuid(12)}' FOR UPDATE;
    SELECT 'fixture-revocation-lock'; SELECT pg_sleep(1.0);
    UPDATE public.account_users SET disabled=true WHERE account_id='${uuid(1)}' AND user_uid='${uuid(12)}'; COMMIT;`);
  let timeout;
  try{
    await Promise.race([acquired,new Promise((_,reject)=>{
      timeout=setTimeout(()=>reject(new Error('Owned revocation lock was not observed')),8000);
    }),completion.then(()=>{if(!output.includes('fixture-revocation-lock'))throw new Error('Revoker ended before lock marker');})]);
    // Bypass RLS only for this trigger-level check: the statement starts before
    // revocation, waits inside its actual guard, and must reject after A commits.
    await assert.rejects(psqlAsync(`BEGIN; SET LOCAL "hasura.user"='${JSON.stringify({'x-hasura-user-id':uuid(12),'x-hasura-role':'user'})}';
      UPDATE public.chat_participants SET muted=true
      WHERE conversation_id='${tenant}' AND user_uid='${uuid(12)}'; ROLLBACK;`),error=>{
      assert.match(String(error.stderr),/chat_current_authority_required/);return true;
    });
    await completion;
    assert.equal(authority(tenant,12).can_read,false);
  }finally{
    clearTimeout(timeout);
    await completion;
    psql(`UPDATE public.account_users SET disabled=false WHERE account_id='${uuid(1)}' AND user_uid='${uuid(12)}';`);
  }
});
test('existing noncreator owner can reopen the real cross-clinic DM RPC',()=>{
  const result=query(`SELECT id FROM public.chat_start_dm('${uuid(11)}')`,{actor:13});
  assert.deepEqual(result,[{id:globalRoom}]);
});
test('same-clinic employee can create a DM through the existing real RPC',()=>{
  const result=query(`SELECT id FROM public.chat_start_dm('${uuid(11)}')`,{actor:12});
  assert.equal(result.length,1);assert.match(result[0].id,/^[0-9a-f-]{36}$/);
});
test('existing support RPC refreshes both participants without changing support scope',()=>{
  const result=query('SELECT id FROM public.chat_start_support()',{actor:11});
  assert.deepEqual(result,[{id:uuid(35)}]);
});
test('removed owner cannot use DM refresh to revive itself',()=>{
  assert.throws(()=>query(`SELECT id FROM public.chat_start_dm('${uuid(11)}')`,{actor:13,
    setup:`UPDATE public.chat_participants SET is_deleted=true WHERE conversation_id='${globalRoom}' AND user_uid='${uuid(13)}'`}),
  error=>/chat_participant_direct_self_join_forbidden|chat_removed_participant_is_not_self_service/.test(String(error.stderr)));
});
test('delivery receipt cannot borrow a message from another conversation',()=>{
  denied(`INSERT INTO public.chat_delivery_receipts(message_id,conversation_id,user_uid)
    VALUES('${uuid(42)}','${tenant}','${uuid(12)}')`,{actor:12},'chat_delivery_message_scope_mismatch');
});
test('delivery receipt identity cannot be retargeted',()=>{
  denied(`UPDATE public.chat_delivery_receipts SET message_id='${uuid(42)}'
    WHERE message_id='${uuid(41)}' AND user_uid='${uuid(12)}'`,{actor:12},'chat_state_identity_is_immutable');
});
test('other member reopening a DM retains the original personal hide marker',()=>{
  const result=query(`SELECT is_deleted,personal_hidden FROM public.chat_participants
    WHERE conversation_id='${globalRoom}' AND user_uid='${uuid(13)}'`,{actor:11,role:'',change:`
      SET LOCAL "hasura.user"='${JSON.stringify({'x-hasura-user-id':uuid(13),'x-hasura-role':'user'})}';
      UPDATE public.chat_participants SET is_deleted=true,deleted_at=now()
        WHERE conversation_id='${globalRoom}' AND user_uid='${uuid(13)}';
      SET LOCAL "hasura.user"='${JSON.stringify({'x-hasura-user-id':uuid(11),'x-hasura-role':'user'})}';
      DO $$ BEGIN PERFORM * FROM public.chat_start_dm('${uuid(13)}'); END $$;
      SET LOCAL "hasura.user"='${JSON.stringify({'x-hasura-user-id':uuid(13),'x-hasura-role':'user'})}';
      UPDATE public.chat_participants SET is_deleted=false
        WHERE conversation_id='${globalRoom}' AND user_uid='${uuid(13)}';
    `});
  assert.deepEqual(result,[{is_deleted:false,personal_hidden:false}]);
});
test('current delivered RPC preserves its SETOF result and own room receipt',()=>{
  const result=query(`SELECT ok,error FROM public.chat_mark_delivered(ARRAY['${uuid(41)}'::uuid])`,{actor:12});
  assert.deepEqual(result,[{ok:true,error:null}]);
});
test('current delivered RPC rejects mixed accessible and inaccessible rooms atomically',()=>{
  denied(`DO $$ BEGIN PERFORM * FROM public.chat_mark_delivered(ARRAY['${uuid(41)}'::uuid,'${uuid(43)}'::uuid]); END $$`,
    {actor:12},'chat_current_authority_required');
});
test('current delivered RPC rechecks revoked clinic membership',()=>{
  denied(`DO $$ BEGIN PERFORM * FROM public.chat_mark_delivered(ARRAY['${uuid(41)}'::uuid]); END $$`,
    {actor:12,setup:`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(12)}'`},
    'chat_current_authority_required');
});
test('active sender keeps edit and tombstone behavior on its own message',()=>{
  const rows=query(`SELECT body,edited,deleted FROM public.chat_messages WHERE id='${uuid(41)}'`,{actor:11,
    change:`UPDATE public.chat_messages SET body='Edited fixture',text='Edited fixture',edited=true,edited_at=now() WHERE id='${uuid(41)}';
      UPDATE public.chat_messages SET deleted=true,deleted_at=now() WHERE id='${uuid(41)}'`});
  assert.deepEqual(rows,[{body:'Edited fixture',edited:true,deleted:true}]);
});
test('revoked sender cannot edit a retained message through SQL guards',()=>{
  denied(`UPDATE public.chat_messages SET body='Denied fixture' WHERE id='${uuid(41)}'`,
    {actor:11,role:'',setup:`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(11)}'`},
    'chat_current_authority_required');
});
test('a superadmin role claim cannot call the admin DM RPC without the active registry',()=>{
  denied(`DO $$ BEGIN PERFORM * FROM public.chat_admin_start_dm('fixture-11@example.invalid'); END $$`,
    {actor:12,claims:{'x-hasura-user-id':uuid(12),'x-hasura-role':'superadmin'}},'forbidden');
});
test('active registry superadmin retains the admin DM RPC',()=>{
  const rows=query(`SELECT id FROM public.chat_admin_start_dm('fixture-12@example.invalid')`,
    {actor:21,claims:{'x-hasura-user-id':uuid(21),'x-hasura-role':'superadmin'}});
  assert.equal(rows.length,1);assert.match(rows[0].id,/^[0-9a-f-]{36}$/);
});
test('disabled support assignment plus independent clinic membership never inherits file admin',()=>{
  const setup=`INSERT INTO public.account_users(account_id,user_uid,role,disabled)
    VALUES('${uuid(1)}','${uuid(25)}','employee',false);
    UPDATE public.chat_support_agents SET is_active=false WHERE user_uid='${uuid(25)}'`;
  const context=query(`SELECT allowed,participant_role FROM public.chat_attachment_access_context('${uuid(35)}','${uuid(25)}')`,
    {actor:25,role:'',setup});
  assert.deepEqual(context,[{allowed:true,participant_role:'support'}]);
  const result=query(`SELECT public.claim_chat_attachment_file('${uuid(92)}','chat-attachments',
    'inactive-support-claim.txt','${uuid(1)}','${uuid(35)}','${uuid(44)}','${uuid(25)}') AS result`,
    {actor:25,role:'',setup});
  assert.equal(result[0].result,'forbidden');
});
