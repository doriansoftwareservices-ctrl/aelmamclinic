const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readSnapshot, ENDPOINT} = require('../tool/acceptance/chat_websocket_read_probe_20261015');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const room = '8f234d4c-6009-48b6-ad7f-8e6d9d2b842a';
const message = 'f42b10e2-2c09-45ea-9695-2b0d9079d2a0';
const actor = {name: 'owner_a', token: 'unit-fixture-memory-token', expected_ids: [message]};

function transport(mode = 'success') {
  const instances = [];
  class Socket extends EventTarget {
    constructor(url, protocol) {
      super(); this.url = url; this.protocol = protocol; this.readyState = 1; this.sent = []; instances.push(this);
      queueMicrotask(() => this.dispatchEvent(new Event('open')));
    }
    send(body) {
      const value = JSON.parse(body); this.sent.push(value);
      const response = value.type === 'connection_init' ? {type: 'connection_ack'} : value.type === 'start' ? {
        id: 'owned-chat-read', type: 'data', payload: mode === 'server_error' ? {errors: [{message: 'private-server-canary'}]} :
          {data: {chat_messages: [{id: message, conversation_id: mode === 'foreign' ? message : room}]}},
      } : null;
      if (response && !(mode === 'idle' && value.type === 'start')) {
        queueMicrotask(() => this.dispatchEvent(new MessageEvent('message', {data: mode === 'invalid_json' ? '{' : JSON.stringify(response)})));
      }
    }
    close() {this.readyState = 3; this.dispatchEvent(new Event('close'));}
  }
  return {Socket, instances};
}

test('trial WebSocket uses the application GraphQL route instead of its metadata host', () => {
  const config = readFileSync(join(__dirname, '../lib/core/nhost_config.dart'), 'utf8');
  assert.ok(config.includes(ENDPOINT.replace('wss://', 'https://')));
  assert.match(ENDPOINT, /\.graphql\.ap-southeast-1\.nhost\.run\/v1$/);
});

test('uses pinned host, current Flutter protocol and only subscription frames', async () => {
  const {Socket, instances} = transport();
  assert.deepEqual(await readSnapshot(actor, room, Socket), [message]);
  assert.equal(instances[0].url, ENDPOINT);
  assert.equal(instances[0].protocol, 'graphql-ws');
  assert.deepEqual(instances[0].sent.map(frame => frame.type), ['connection_init', 'start', 'stop']);
  assert.match(instances[0].sent[1].payload.query, /^subscription /);
  assert.doesNotMatch(instances[0].sent[1].payload.query, /mutation/);
  assert.equal(instances[0].readyState, 3);
});

test('unapproved actor is rejected before connecting', async () => {
  const {Socket, instances} = transport();
  await assert.rejects(readSnapshot({...actor, name: 'real-user'}, room, Socket), /invalid_owned_websocket_fixture/);
  assert.equal(instances.length, 0);
});

test('foreign room data is rejected and socket is closed', async () => {
  const {Socket, instances} = transport('foreign');
  await assert.rejects(readSnapshot(actor, room, Socket), /unexpected_snapshot_scope/);
  assert.equal(instances[0].readyState, 3);
});

test('server errors never echo private payloads', async () => {
  const {Socket} = transport('server_error');
  await assert.rejects(readSnapshot(actor, room, Socket), error =>
    error.message === 'websocket_subscription_rejected' && !error.stack.includes('private-server-canary'));
});

test('malformed frames and missing snapshots stop within the bounded deadline', async () => {
  await assert.rejects(readSnapshot(actor, room, transport('invalid_json').Socket), /invalid_websocket_frame/);
  const {Socket, instances} = transport('idle');
  await assert.rejects(readSnapshot(actor, room, Socket, 30), /bounded_websocket_read_timeout/);
  assert.equal(instances[0].readyState, 3);
});
