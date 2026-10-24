'use strict';
const {spawn} = require('node:child_process');
const {createInterface} = require('node:readline');

// No caller-selectable endpoint/database. Opt-in is required even for importers.
function openNotificationFixture() {
  if (process.env.ELMAM_NOTIFICATION_AUTHORITY_FIXTURE !== 'owned_pg14_20261023') throw new Error('owned_fixture_opt_in_required');
  const docker = '/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe';
  const container = 'elmam-remediation-pg14-v2-20261021';
  const database = 'elmam_notification_delivery_v2_v1';
  let serial = 0;
  const pending = new Map();
  const python = `import sys,json,urllib.request,urllib.error
for line in sys.stdin:
 try:
  value=json.loads(line);headers={'Content-Type':'application/json','x-hasura-admin-secret':'elmam_fixture_admin_only'}
  if value.get('actor'):
   actor=value['actor'];assert actor['role'] in ['user','superadmin','me','owner','employee','support']
   headers.update({'x-hasura-role':actor['role'],'x-hasura-user-id':actor['uid']})
  is_sql='sql' in value
  payload={'type':'run_sql','args':{'source':'default','sql':value['sql'],'read_only':False,'check_metadata_consistency':False}} if is_sql else {'query':value['document'],'variables':value.get('variables',{})}
  req=urllib.request.Request('http://127.0.0.1:8085'+('/v2/query' if is_sql else '/v1/graphql'),json.dumps(payload).encode(),headers)
  try:
   with urllib.request.urlopen(req,timeout=10) as response:status=response.status;body=json.load(response)
  except urllib.error.HTTPError as response:status=response.code;body=json.load(response)
  print(json.dumps({'id':value['id'],'status':status,'body':body}),flush=True)
 except Exception as error:print(json.dumps({'id':value.get('id'),'error':type(error).__name__}),flush=True)
`;
  const child = spawn(docker, ['run', '--rm', '-i', '--network', 'container:' + container,
    '--entrypoint', 'python3', 'public.ecr.aws/supabase/postgres:17.4.1.069', '-u', '-c', python]);
  child.stderr.resume();
  createInterface({input: child.stdout}).on('line', line => {
    const reply = JSON.parse(line);const item = pending.get(reply.id);
    if (!item) return;
    pending.delete(reply.id);item.cleanup();
    if (reply.error) item.reject(new Error('owned_fixture_transport_failed:' + reply.error));
    else item.resolve(reply);
  });
  const request = (document, variables = {}, actor = null, signal, sqlStatement) => new Promise((resolve, reject) => {
    if (signal?.aborted) {reject(new Error('owned_fixture_request_aborted'));return;}
    const id = ++serial;
    const abort = () => {pending.delete(id);cleanup();reject(new Error('owned_fixture_request_aborted'));};
    const timer = setTimeout(abort, 15000);
    const cleanup = () => {clearTimeout(timer);signal?.removeEventListener('abort', abort);};
    signal?.addEventListener('abort', abort, {once: true});
    pending.set(id, {resolve, reject, cleanup});
    child.stdin.write(JSON.stringify({id, document, variables, actor, ...(sqlStatement === undefined ? {} : {sql: sqlStatement})}) + '\n');
  });
  // Reuse the already-started bridge. Starting docker.exe for every SQL call
  // adds Windows/WSL interop stalls unrelated to the product's HTTP deadline.
  // Hasura executes this one multi-statement SQL request atomically; an actual
  // rollback-and-recovery test below verifies that fixture contract.
  const sql = async statement => {
    const guarded = "DO $$ BEGIN IF current_database()<>'" + database +
      "' THEN RAISE EXCEPTION 'owned_fixture_only';END IF;END $$;" + statement + ';';
    const reply = await request(undefined, {}, null, undefined, guarded);
    if (reply.status !== 200 || !['TuplesOk', 'CommandOk'].includes(reply.body?.result_type)) {
      throw new Error('owned_fixture_SQL_failed');
    }
    return reply.body.result_type === 'CommandOk' ? '' : reply.body.result.slice(1)
      .map(row => row.map(value => value ?? '').join('|')).join('\n');
  };
  return {
    sql,
    async query({document, variables, actor}) {
      const reply = await request(document, variables, actor);
      if (reply.status !== 200 || reply.body.errors) throw new Error('owned_fixture_graphql_unavailable');
      return reply.body.data;
    },
    async fetchImpl(_url, options) {
      const body = JSON.parse(options.body);
      const reply = await request(body.query, body.variables, null, options.signal);
      return {status: reply.status, ok: reply.status === 200, json: async () => reply.body};
    },
    close: () => new Promise((resolve, reject) => {
      const timer = setTimeout(() => {child.kill();reject(new Error('owned_bridge_cleanup_timeout'));}, 20000);
      child.on('exit', code => {clearTimeout(timer);if (code) reject(new Error('owned_bridge_exit_failure'));else resolve();});
      child.stdin.end();
    }),
  };
}
module.exports = {openNotificationFixture};
