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
  req=urllib.request.Request('http://127.0.0.1:8085/v1/graphql',json.dumps({'query':value['document'],'variables':value.get('variables',{})}).encode(),headers)
  try:
   with urllib.request.urlopen(req,timeout=3) as response:status=response.status;body=json.load(response)
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
    if (reply.error) item.reject(new Error('owned_fixture_transport_failed'));
    else item.resolve(reply);
  });
  const request = (document, variables = {}, actor = null, signal) => new Promise((resolve, reject) => {
    if (signal?.aborted) {reject(new Error('owned_fixture_request_aborted'));return;}
    const id = ++serial;
    const abort = () => {pending.delete(id);cleanup();reject(new Error('owned_fixture_request_aborted'));};
    const timer = setTimeout(abort, 15000);
    const cleanup = () => {clearTimeout(timer);signal?.removeEventListener('abort', abort);};
    signal?.addEventListener('abort', abort, {once: true});
    pending.set(id, {resolve, reject, cleanup});
    child.stdin.write(JSON.stringify({id, document, variables, actor}) + '\n');
  });
  const sql = statement => new Promise((resolve, reject) => {
    const process = spawn(docker, ['exec', '-i', container, 'psql', '-U', 'postgres',
      '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database]);
    let stdout = '';let stderr = '';
    process.stdout.on('data', value => {stdout += value;});
    process.stderr.on('data', value => {stderr += value;});
    const timer = setTimeout(() => {process.kill();reject(new Error('owned_fixture_SQL_timeout'));}, 20000);
    process.on('error', reject);
    process.on('exit', code => {
      clearTimeout(timer);if (code) reject(new Error('owned_fixture_SQL_failed:' + stderr));else resolve(stdout.trim());
    });
    process.stdin.end("BEGIN;DO $$ BEGIN IF current_database()<>'" + database +
      "' THEN RAISE EXCEPTION 'owned_fixture_only';END IF;END $$;" + statement + ';COMMIT;');
  });
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
