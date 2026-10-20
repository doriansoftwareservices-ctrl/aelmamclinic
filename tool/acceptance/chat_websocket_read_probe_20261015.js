// Read-only subscription probe; credentials enter through stdin and stay in memory.
const ENDPOINT = 'wss://nbbywmmebvxegshrvgic.graphql.ap-southeast-1.nhost.run/v1';
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const DOCUMENT = `subscription ChatAcceptanceRead($cid: uuid!) {
  chat_messages(where: {conversation_id: {_eq: $cid}},
    order_by: [{created_at: desc}, {id: desc}], limit: 12) {
    id conversation_id
  }
}`;

function failure(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

async function readSnapshot(actor, conversationId, WebSocketType = WebSocket, timeoutMs = 20000) {
  if (!['owner_a', 'employee_a'].includes(actor?.name) || !UUID.test(conversationId) ||
      typeof actor.token !== 'string' || actor.token.length < 16 || actor.token.length > 16384 ||
      !Array.isArray(actor.expected_ids) || actor.expected_ids.length > 12 ||
      !actor.expected_ids.every(id => UUID.test(id))) {
    throw failure('invalid_owned_websocket_fixture');
  }
  return new Promise((resolve, reject) => {
    let socket;
    let subscribed = false;
    let settled = false;
    const finish = (error, ids) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        if (socket?.readyState === 1 && subscribed) socket.send(JSON.stringify({id: 'owned-chat-read', type: 'stop'}));
        socket?.close(1000, 'Read acceptance complete');
      } catch (_) { /* Closing an already-failed owned socket must not leak the token. */ }
      if (error) reject(error); else resolve(ids);
    };
    const timer = setTimeout(() => finish(failure('bounded_websocket_read_timeout')), timeoutMs);
    try {
      socket = new WebSocketType(ENDPOINT, 'graphql-ws');
      socket.addEventListener('open', () => {
        if (socket.protocol !== 'graphql-ws') return finish(failure('unexpected_websocket_protocol'));
        socket.send(JSON.stringify({type: 'connection_init', payload: {headers: {
          Authorization: 'Bearer ' + actor.token, 'x-hasura-role': 'user',
        }}}));
      });
      socket.addEventListener('message', event => {
        try {
          if (typeof event.data !== 'string' || event.data.length > 65536) throw failure('unexpected_websocket_frame');
          const message = JSON.parse(event.data);
          if (message.type === 'ka') return;
          if (message.type === 'connection_ack') {
            if (subscribed) throw failure('duplicate_websocket_ack');
            subscribed = true;
            socket.send(JSON.stringify({id: 'owned-chat-read', type: 'start', payload: {
              query: DOCUMENT, variables: {cid: conversationId},
            }}));
            return;
          }
          if (message.type !== 'data' || message.id !== 'owned-chat-read' || !subscribed || message.payload?.errors) {
            throw failure('websocket_subscription_rejected');
          }
          const rows = message.payload?.data?.chat_messages;
          if (!Array.isArray(rows) || rows.length > 12 || rows.some(row =>
              !UUID.test(row.id) || row.conversation_id !== conversationId)) throw failure('unexpected_snapshot_scope');
          const ids = rows.map(row => row.id).sort();
          if (new Set(ids).size !== ids.length || JSON.stringify(ids) !== JSON.stringify([...actor.expected_ids].sort())) {
            throw failure('websocket_snapshot_differs_from_owned_http_history');
          }
          finish(null, ids);
        } catch (error) { finish(failure(error.code || 'invalid_websocket_frame')); }
      });
      socket.addEventListener('error', () => finish(failure('websocket_transport_failed')));
      socket.addEventListener('close', () => finish(failure('websocket_closed_before_snapshot')));
    } catch (_) { finish(failure('websocket_transport_setup_failed')); }
  });
}

module.exports = {readSnapshot, ENDPOINT};

if (require.main === module) {
  let body = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    body += chunk;
    if (body.length > 65536) process.exit(1);
  });
  process.stdin.on('end', async () => {
    try {
      const input = JSON.parse(body);
      body = '';
      if (input.actors?.length !== 2 || input.actors[0].name !== 'owner_a' || input.actors[1].name !== 'employee_a') {
        throw failure('invalid_owned_websocket_actors');
      }
      const results = [];
      for (const actor of input.actors) {
        for (const stage of ['initial', 'reconnect']) {
          const ids = await readSnapshot(actor, input.conversation_id);
          results.push({actor: actor.name, stage, message_ids: ids, passed: true});
        }
      }
      console.log(JSON.stringify({result: 'PASS_WEBSOCKET_SNAPSHOTS_AND_RECONNECT', results,
        node_version: process.version, platform: process.platform, new_messages: 0, native_device_acceptance: false, publication_event_delivery_accepted: false}));
    } catch (error) {
      console.log(JSON.stringify({result: 'WEBSOCKET_READ_NOT_ACCEPTED', diagnostic: error.code || 'owned_websocket_probe_failed'}));
      process.exitCode = 1;
    }
  });
}
