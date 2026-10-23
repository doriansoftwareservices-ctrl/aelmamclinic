'use strict';
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs');
const path=require('node:path');
const test=require('node:test');
const subscribeMessages=require('./chat_acl_websocket_helper.cjs');
const base=new URL(process.env.ELMAM_CHAT_ACL_HASURA_URL);
assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');
assert.ok(Number(base.port)>1024);
const admin=process.env.ELMAM_CHAT_ACL_ADMIN;
const key=process.env.ELMAM_CHAT_ACL_JWT;
assert.ok(admin?.length>=32);assert.ok(key?.length>=32);
const metadataPath=process.env.ELMAM_CHAT_ACL_METADATA;
const uuid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const tenant=uuid(31),globalRoom=uuid(32);
const roomMessage=room=>uuid(room===tenant?41:room===globalRoom?42:room===uuid(35)?44:43);
function token(actor,roles=['user','me',...(actor===21?['superadmin']:actor===25?['support']:['employee'])]){
  const header=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
  const payload=Buffer.from(JSON.stringify({sub:uuid(actor),iat:Math.floor(Date.now()/1000),
    exp:Math.floor(Date.now()/1000)+300,'https://hasura.io/jwt/claims':{
      'x-hasura-user-id':uuid(actor),'x-hasura-default-role':'user','x-hasura-allowed-roles':roles,
    }})).toString('base64url');
  return `${header}.${payload}.${crypto.createHmac('sha256',key).update(`${header}.${payload}`).digest('base64url')}`;
}
async function post(route,body,headers){
  assert.ok(['/v1/graphql','/v1/metadata','/v2/query'].includes(route));
  const response=await fetch(new URL(route,base),{method:'POST',redirect:'error',
    headers:{'content-type':'application/json',...headers},body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
  return {status:response.status,body:await response.json()};
}
async function gql(query,actor=12,{role='user',roles,headers={}}={}){
  return post('/v1/graphql',{query},{authorization:`Bearer ${token(actor,roles)}`,'x-hasura-role':role,...headers});
}
async function sql(statement){
  const result=await post('/v2/query',{type:'run_sql',args:{source:'default',sql:statement,read_only:false}},
    {'x-hasura-admin-secret':admin});
  assert.equal(result.status,200,`Local fixture SQL failed (${result.status})`);
  assert.ok(!result.body.error,'Local fixture SQL failed');
  return result.body;
}
const probeQuery=room=>`query {
  chat_conversations(where:{id:{_eq:"${room}"}}){id}
  chat_messages(where:{conversation_id:{_eq:"${room}"}}){id}
  chat_participants(where:{conversation_id:{_eq:"${room}"}}){user_uid}
  chat_reads(where:{conversation_id:{_eq:"${room}"}}){user_uid}
  chat_typing(where:{conversation_id:{_eq:"${room}"}}){user_uid}
  chat_delivery_receipts(where:{conversation_id:{_eq:"${room}"}}){user_uid}
  chat_reactions(where:{message_id:{_eq:"${roomMessage(room)}"}}){user_uid emoji}
  v_chat_last_message(where:{conversation_id:{_eq:"${room}"}}){conversation_id}
  v_chat_conversations_for_me(where:{id:{_eq:"${room}"}}){id}
  v_chat_reads_for_me(where:{conversation_id:{_eq:"${room}"}}){conversation_id}
  v_chat_typing_active(where:{conversation_id:{_eq:"${room}"}}){conversation_id}
}`;
async function probe(room,actor,options){
  const result=await gql(probeQuery(room),actor,options);
  assert.equal(result.status,200);assert.equal(result.body.errors,undefined,
    result.body.errors?.map(error=>error.message).join('; '));
  return result.body.data;
}
function empty(data){for(const [surface,rows]of Object.entries(data))assert.deepEqual(rows,[],surface);}

test.before(async()=>{
  const metadata=JSON.parse(fs.readFileSync(metadataPath,'utf8'));
  const result=await post('/v1/metadata',{type:'replace_metadata',args:{allow_inconsistent_metadata:false,metadata}},
    {'x-hasura-admin-secret':admin});
  fs.writeFileSync(path.join(path.dirname(metadataPath),'chat_acl_metadata_apply_result.json'),JSON.stringify(result,null,2));
  assert.equal(result.status,200,`Real Hasura metadata application failed: ${result.body.error||'unknown'}`);
  const consistent=await post('/v1/metadata',{type:'get_inconsistent_metadata',args:{}},{'x-hasura-admin-secret':admin});
  assert.equal(consistent.body.is_consistent,true);
  const marker=await sql("SELECT value FROM public.elmam_chat_acl_fixture_marker;");
  assert.equal(marker.result[1][0],'local_chat_acl_scope_20261019');
  await sql('UPDATE public.chat_typing SET updated_at=now();');
  await sql(`INSERT INTO public.chat_reactions(account_id,message_id,user_uid,emoji)
    VALUES('${uuid(1)}','${uuid(41)}','${uuid(12)}','fixture');`);
});

for(const[label,actor,room,role]of[
  ['tenant employee',12,tenant,'employee'],['tenant owner',11,tenant,'user'],
  ['global owner',13,globalRoom,'user'],['assigned support',25,uuid(35),'support'],
]){
  test(`real Hasura accepts current ${label} JWT`,async()=>{
    const data=await probe(room,actor,{role});
    assert.ok(data.chat_conversations.length>0);assert.ok(data.chat_messages.length>0);
    assert.ok(data.v_chat_last_message.length>0);
    assert.ok(data.v_chat_conversations_for_me.length>0,'authorized role must see its own conversation preview');
  });
}
test('real Hasura preview read cursors and unread count are actor-specific',async()=>{
  const room=tenant;
  await sql("UPDATE public.chat_reads SET last_read_at=now()-interval '2 days' WHERE conversation_id='"+room+"' AND user_uid IN ('"+uuid(11)+"','"+uuid(12)+"')");
  const query='query {v_chat_conversations_for_me(where:{id:{_eq:"'+room+'"}}){id last_read_at unread_count} v_chat_reads_for_me(where:{conversation_id:{_eq:"'+room+'"}}){user_uid conversation_id}}';
  try {
    const owner=await gql(query,11,{role:'user'});
    const employee=await gql(query,12,{role:'employee'});
    assert.equal(owner.body.errors,undefined,JSON.stringify(owner.body.errors));
    assert.equal(employee.body.errors,undefined,JSON.stringify(employee.body.errors));
    assert.equal(owner.body.data.v_chat_conversations_for_me.length,1,'owner preview cardinality');
    assert.equal(employee.body.data.v_chat_conversations_for_me.length,1,'employee preview cardinality');
    assert.equal(owner.body.data.v_chat_conversations_for_me[0].unread_count,0,'owner own message not unread');
    assert.equal(employee.body.data.v_chat_conversations_for_me[0].unread_count,1,'recipient sees unread message once');
    assert.deepEqual(owner.body.data.v_chat_reads_for_me.map(x=>x.user_uid),[uuid(11)],'own cursor only');
    assert.deepEqual(employee.body.data.v_chat_reads_for_me.map(x=>x.user_uid),[uuid(12)],'own cursor only');
  } finally {
    await sql("UPDATE public.chat_reads SET last_read_at=now() WHERE conversation_id='"+room+"' AND user_uid IN ('"+uuid(11)+"','"+uuid(12)+"')");
  }
});

for(const[label,actor,room]of[
  ['foreign clinic participant',13,tenant],['global employee',12,globalRoom],
  ['global outsider owner',14,globalRoom],['inactive support',26,uuid(35)],
  ['support outside its assigned room',25,globalRoom],['support participant in group',25,tenant],
])test(`real Hasura denies ${label} across all chat read surfaces`,async()=>empty(await probe(room,actor)));

for(const[label,change,restore,actor,room,role]of[
  ['membership revoked',`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(12)}'`,
    `UPDATE public.account_users SET disabled=false WHERE user_uid='${uuid(12)}'`,12,tenant,'user'],
  ['clinic frozen',`UPDATE public.accounts SET frozen=true WHERE id='${uuid(1)}'`,
    `UPDATE public.accounts SET frozen=false WHERE id='${uuid(1)}'`,12,tenant,'user'],
  ['global owner demoted',`UPDATE public.account_users SET role='employee' WHERE user_uid='${uuid(13)}'`,
    `UPDATE public.account_users SET role='owner' WHERE user_uid='${uuid(13)}'`,13,globalRoom,'user'],
  ['Auth disabled',`UPDATE auth.users SET disabled=true WHERE id='${uuid(12)}'`,
    `UPDATE auth.users SET disabled=false WHERE id='${uuid(12)}'`,12,tenant,'user'],
  ['support assignment revoked',`UPDATE public.chat_support_agents SET is_active=false WHERE user_uid='${uuid(25)}'`,
    `UPDATE public.chat_support_agents SET is_active=true WHERE user_uid='${uuid(25)}'`,25,uuid(35),'support'],
  ['superadmin registry revoked',`UPDATE public.super_admins SET disabled=true WHERE user_uid='${uuid(21)}'`,
    `UPDATE public.super_admins SET disabled=false WHERE user_uid='${uuid(21)}'`,21,globalRoom,'superadmin'],
])test(`an existing JWT loses real Hasura reads after ${label}`,async()=>{
  await sql(change);try{empty(await probe(room,actor,{role}));}finally{await sql(restore);}
});

test('active superadmin JWT cannot bypass frozen tenant scope',async()=>{
  await sql(`UPDATE public.accounts SET frozen=true WHERE id='${uuid(1)}'`);
  try{empty(await probe(tenant,21,{role:'superadmin'}));}
  finally{await sql(`UPDATE public.accounts SET frozen=false WHERE id='${uuid(1)}'`);}
});
test('forbidden role header cannot escalate an ordinary JWT',async()=>{
  const result=await gql(probeQuery(globalRoom),12,{role:'superadmin'});
  assert.ok(result.status===400||result.status===401||result.body.errors?.length>0);
});
test('an allowed owner role header cannot replace current DB membership',async()=>{
  empty(await probe(globalRoom,12,{role:'owner',roles:['user','owner']}));
});
test('a forged allowed superadmin claim cannot replace the active registry',async()=>{
  empty(await probe(tenant,12,{role:'superadmin',roles:['user','superadmin']}));
});
test('a user-id request header cannot replace the JWT identity',async()=>{
  empty(await probe(globalRoom,12,{headers:{'x-hasura-user-id':uuid(13)}}));
});
test('private authority tables are absent from an ordinary GraphQL schema',async()=>{
  const result=await gql('{chat_current_access{conversation_id user_uid}}');
  assert.ok(result.body.errors?.length>0);
});
for(const[field,value]of[['role','"owner"'],['conversation_id',`"${uuid(34)}"`],['account_id',`"${uuid(2)}"`],['user_uid',`"${uuid(14)}"`]]){
  test(`ordinary GraphQL mutation schema excludes participant ${field}`,async()=>{
    const result=await gql(`mutation{update_chat_participants(where:{conversation_id:{_eq:"${tenant}"},user_uid:{_eq:"${uuid(12)}"}},_set:{${field}:${value}}){affected_rows}}`);
    assert.ok(result.body.errors?.length>0);
    assert.ok(result.body.errors.some(error=>/not found|field.*not defined|does not exist/i.test(error.message)));
  });
}
test('ordinary mute and read cursor updates remain available',async()=>{
  const result=await gql(`mutation{update_chat_participants(where:{conversation_id:{_eq:"${tenant}"},user_uid:{_eq:"${uuid(12)}"}},_set:{muted:true,last_read_at:"2026-10-19T00:00:00Z"}){affected_rows}}`);
  assert.equal(result.body.errors,undefined);assert.equal(result.body.data.update_chat_participants.affected_rows,1);
});
test('ordinary personal hide and unhide both work through real Hasura',async()=>{
  for(const hidden of[true,false]){
    const result=await gql(`mutation{update_chat_participants(where:{conversation_id:{_eq:"${tenant}"},user_uid:{_eq:"${uuid(12)}"}},_set:{is_deleted:${hidden}}){affected_rows}}`);
    assert.equal(result.body.errors,undefined);assert.equal(result.body.data.update_chat_participants.affected_rows,1);
  }
});
test('removed participant cannot resurrect through a GraphQL update',async()=>{
  const result=await gql(`mutation{update_chat_participants(where:{conversation_id:{_eq:"${tenant}"},user_uid:{_eq:"${uuid(24)}"}},_set:{is_deleted:false}){affected_rows}}`,24);
  assert.equal(result.body.errors,undefined);assert.equal(result.body.data.update_chat_participants.affected_rows,0);
});
test('creator bootstrap keeps the real createGroup ON CONFLICT fields',async()=>{
  const result=await gql(`mutation{insert_chat_participants(objects:[{conversation_id:"${uuid(34)}",user_uid:"${uuid(11)}",account_id:"${uuid(1)}",role:"owner",email:"creator@example.invalid",joined_at:"2026-10-19T00:00:00Z"}],on_conflict:{constraint:chat_participants_pkey,update_columns:[email,joined_at]}){affected_rows}}`,11);
  assert.equal(result.body.errors,undefined);assert.equal(result.body.data.insert_chat_participants.affected_rows,1);
});
test('foreign-room self join rejects the actor supplied own clinic',async()=>{
  const result=await gql(`mutation{insert_chat_participants(objects:[{conversation_id:"${uuid(33)}",user_uid:"${uuid(12)}",account_id:"${uuid(1)}",role:"owner"}]){affected_rows}}`);
  assert.ok(result.body.errors?.length>0);
});
test('foreign-message receipt cursor is rejected by actual SQL behind Hasura',async()=>{
  const result=await gql(`mutation{insert_chat_delivery_receipts(objects:[{conversation_id:"${tenant}",user_uid:"${uuid(12)}",message_id:"${uuid(42)}"}]){affected_rows}}`);
  assert.ok(result.body.errors?.length>0);
});
test('real current DM RPC uses current tenant scope instead of a stale global room',async()=>{
  const result=await gql(`mutation{chat_start_dm(args:{p_other_uid:"${uuid(11)}"}){id}}`,12);
  assert.equal(result.body.errors,undefined);assert.equal(result.body.data.chat_start_dm.length,1);
  const id=result.body.data.chat_start_dm[0].id;
  assert.notEqual(id,globalRoom);
  const scope=await sql(`SELECT account_id::text FROM public.chat_conversations WHERE id='${id}'`);
  assert.equal(scope.result[1][0],uuid(1));
});
test('real existing support RPC keeps the assigned support room',async()=>{
  const result=await gql('mutation{chat_start_support{id}}',11);
  assert.equal(result.body.errors,undefined);
  assert.deepEqual(result.body.data.chat_start_support,[{id:uuid(35)}]);
});
test('current delivered RPC return contract works through real Hasura',async()=>{
  const result=await gql(`mutation{chat_mark_delivered(args:{p_message_ids:"{${uuid(41)}}"}){ok error}}`,12);
  assert.equal(result.body.errors,undefined);
  assert.deepEqual(result.body.data.chat_mark_delivered,[{ok:true,error:null}]);
});
test('current delivered RPC remains available to its existing employee role permission',async()=>{
  const result=await gql(`mutation{chat_mark_delivered(args:{p_message_ids:"{${uuid(41)}}"}){ok}}`,12,{role:'employee'});
  assert.equal(result.body.errors,undefined);
  assert.deepEqual(result.body.data.chat_mark_delivered,[{ok:true}]);
});
test('current delivered RPC rejects mixed-room message IDs atomically through Hasura',async()=>{
  const before=await sql(`SELECT delivered_at::text FROM public.chat_delivery_receipts WHERE message_id='${uuid(41)}' AND user_uid='${uuid(12)}'`);
  const result=await gql(`mutation{chat_mark_delivered(args:{p_message_ids:"{${uuid(41)},${uuid(43)}}"}){ok}}`,12);
  assert.ok(result.body.errors?.length>0);
  const rows=await sql(`SELECT count(*) FROM public.chat_delivery_receipts WHERE message_id='${uuid(43)}' AND user_uid='${uuid(12)}'`);
  assert.equal(rows.result[1][0],'0');
  const after=await sql(`SELECT delivered_at::text FROM public.chat_delivery_receipts WHERE message_id='${uuid(41)}' AND user_uid='${uuid(12)}'`);
  assert.equal(after.result[1][0],before.result[1][0]);
});
test('current delivered RPC rejects an already disabled Auth identity',async()=>{
  await sql(`UPDATE auth.users SET disabled=true WHERE id='${uuid(12)}'`);
  try{
    const result=await gql(`mutation{chat_mark_delivered(args:{p_message_ids:"{${uuid(41)}}"}){ok}}`,12);
    assert.ok(result.body.errors?.length>0);
  }finally{await sql(`UPDATE auth.users SET disabled=false WHERE id='${uuid(12)}'`);}
});
test('admin DM RPC rejects a role claim without current registry authority',async()=>{
  const before=await sql(`SELECT count(*) FROM public.chat_conversations WHERE created_by='${uuid(12)}'`);
  const result=await gql('mutation{chat_admin_start_dm(args:{target_email:"fixture-23@example.invalid"}){id}}',12,
    {role:'superadmin',roles:['user','superadmin']});
  const after=await sql(`SELECT count(*) FROM public.chat_conversations WHERE created_by='${uuid(12)}'`);
  assert.equal(after.result[1][0],before.result[1][0], 'Forged superadmin role must not create a room');
  assert.ok(result.body.errors?.length>0 || result.body.data?.chat_admin_start_dm?.length===0);
});
test('active registry superadmin retains the real admin DM RPC',async()=>{
  const result=await gql('mutation{chat_admin_start_dm(args:{target_email:"fixture-12@example.invalid"}){id}}',21,
    {role:'superadmin'});
  assert.equal(result.body.errors,undefined);assert.equal(result.body.data.chat_admin_start_dm.length,1);
});
test('real WebSocket revokes live reads and reconnects with current authority using the same JWT',async()=>{
  const authorization=`Bearer ${token(12)}`;
  let subscription=subscribeMessages(base,authorization,tenant);
  try{
    await subscription.waitFor(rows=>rows.some(row=>row.id===uuid(41)));
    await sql(`UPDATE public.account_users SET disabled=true WHERE user_uid='${uuid(12)}'`);
    await subscription.waitFor(rows=>rows.length===0);
    await subscription.close();
    subscription=subscribeMessages(base,authorization,tenant);
    await subscription.waitFor(rows=>rows.length===0);
    await sql(`UPDATE public.account_users SET disabled=false WHERE user_uid='${uuid(12)}'`);
    await subscription.waitFor(rows=>rows.some(row=>row.id===uuid(41)));
  }finally{
    await sql(`UPDATE public.account_users SET disabled=false WHERE user_uid='${uuid(12)}'`);
    await subscription.close();
  }
});
test('actual client message insert and conflict retry preserve one immutable message',async()=>{
  const object=`{id:"${uuid(75)}",conversation_id:"${tenant}",account_id:"${uuid(1)}",sender_uid:"${uuid(12)}",kind:"text",body:"Fixture new message",text:"Fixture new message",client_msg_id:"fixture-client-message-75",device_id:"fixture-device",local_id:75}`;
  const mutation=`mutation{insert_chat_messages(objects:[${object}],on_conflict:{constraint:chat_messages_conversation_client_msg_id_key,update_columns:[]}){affected_rows returning{id client_msg_id}}}`;
  const first=await gql(mutation,12);
  assert.equal(first.body.errors,undefined);assert.equal(first.body.data.insert_chat_messages.affected_rows,1);
  const retry=await gql(mutation,12);
  assert.equal(retry.body.errors,undefined);assert.equal(retry.body.data.insert_chat_messages.affected_rows,0);
  const received=await gql(`{chat_messages(where:{conversation_id:{_eq:"${tenant}"},client_msg_id:{_eq:"fixture-client-message-75"}}){id body}}`,11);
  assert.equal(received.body.errors,undefined);
  assert.deepEqual(received.body.data.chat_messages,[{id:uuid(75),body:'Fixture new message'}]);
});
test('real sender can edit then tombstone its message while another participant sees the result',async()=>{
  const edit=await gql(`mutation{update_chat_messages(where:{id:{_eq:"${uuid(75)}"}},_set:{body:"Fixture edited message",text:"Fixture edited message",edited:true}){affected_rows}}`,12);
  assert.equal(edit.body.errors,undefined);assert.equal(edit.body.data.update_chat_messages.affected_rows,1);
  const received=await gql(`{chat_messages(where:{id:{_eq:"${uuid(75)}"}}){body edited}}`,11);
  assert.deepEqual(received.body.data.chat_messages,[{body:'Fixture edited message',edited:true}]);
  const tombstone=await gql(`mutation{update_chat_messages(where:{id:{_eq:"${uuid(75)}"}},_set:{deleted:true}){affected_rows}}`,12);
  assert.equal(tombstone.body.errors,undefined);assert.equal(tombstone.body.data.update_chat_messages.affected_rows,1);
  const visible=await gql(`{chat_messages(where:{id:{_eq:"${uuid(75)}"},deleted:{_neq:true}}){id}}`,11);
  assert.deepEqual(visible.body.data.chat_messages,[]);
});
test('real reactions retain self ownership and reject foreign-room identifiers',async()=>{
  const own=await gql(`mutation{update_chat_reactions(where:{message_id:{_eq:"${uuid(41)}"},user_uid:{_eq:"${uuid(12)}"},emoji:{_eq:"fixture"}},_set:{is_deleted:true}){affected_rows}}`,12);
  assert.equal(own.body.errors,undefined);assert.equal(own.body.data.update_chat_reactions.affected_rows,1);
  const foreign=await gql(`mutation{insert_chat_reactions(objects:[{message_id:"${uuid(43)}",user_uid:"${uuid(12)}",account_id:"${uuid(1)}",emoji:"foreign"}]){affected_rows}}`,12);
  assert.ok(foreign.body.errors?.length>0);
});
