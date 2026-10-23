'use strict';

// Fixed admin-only operations. The public endpoint must never accept arbitrary
// GraphQL, an actor UID or rollout controls from a caller.
const {NotificationDispatchUnavailable} = require('./notification_dispatch_v2');
const fields = `id event_id user_uid token_id installation_id ack_nonce status attempts
  worker_id lease_token lease_until delivery_event {event_id event_type source_id account_id}`;
const documents = Object.freeze({
  enabled: `query NotificationDispatchBarrier {
    notification_delivery_control_v2 {capture_enabled dispatch_enabled}
  }`,
  claim: `mutation ClaimNotificationDestinations($worker: uuid!, $limit: Int!) {
    claim_notification_targets_v2(args: {p_worker: $worker, p_limit: $limit}) {${fields}}
  }`,
  admit: `mutation AdmitNotificationDestination($id: uuid!, $lease: uuid!, $registration: uuid!, $token: String!) {
    admit_notification_target_v2(args: {p_id: $id, p_lease: $lease, p_registration: $registration, p_token: $token}) {
      id event_id user_uid installation_id status lease_token
    }
  }`,
  finish: `mutation FinishNotificationDestination($id: uuid!, $lease: uuid!, $outcome: String!, $error: String, $provider: String) {
    finish_notification_target_v2(args: {p_id: $id, p_lease: $lease, p_outcome: $outcome,
      p_error: $error, p_provider_message_id: $provider}) {
      id event_id user_uid installation_id status provider_message_id
    }
  }`,
  deactivate: `mutation RetireNotificationRegistration($id: uuid!, $uid: uuid!, $installation: uuid!, $token: String!) {
    deactivate_notification_registration_v2(args: {p_id: $id, p_uid: $uid, p_installation: $installation, p_token: $token}) {
      id user_uid installation_id is_active
    }
  }`,
});
const fail = () => {throw new NotificationDispatchUnavailable();};
const same = (left, right) => typeof left === 'string' && typeof right === 'string' && left.toLowerCase() === right.toLowerCase();

function createNotificationRepositoryV2({url, adminSecret, fetchImpl = globalThis.fetch, timeoutMs = 3500}) {
  if (typeof url !== 'string' || !/^https?:\/\//.test(url) || !url.endsWith('/v1/graphql') ||
    typeof adminSecret !== 'string' || !adminSecret || typeof fetchImpl !== 'function' ||
    !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 4000) fail();
  const request = async (document, variables, signal) => {
    const controller = new AbortController();let timer;let rejectAbort;
    const abort = () => {controller.abort();rejectAbort?.(new NotificationDispatchUnavailable());};
    try {
      if (signal?.aborted) fail();
      signal?.addEventListener('abort', abort, {once: true});
      const deadline = new Promise((_, reject) => {rejectAbort = reject;timer = setTimeout(abort, timeoutMs);});
      const operation = (async () => {
        const response = await fetchImpl(url, {method: 'POST', signal: controller.signal,
          headers: Object.freeze({'Content-Type': 'application/json', 'x-hasura-admin-secret': adminSecret}),
          body: JSON.stringify({query: document, variables})});
        const result = await response.json();
        if (!response.ok || result.errors || !result.data || typeof result.data !== 'object' || Array.isArray(result.data)) fail();
        return result.data;
      })();
      return await Promise.race([operation, deadline]);
    } catch (_) {throw new NotificationDispatchUnavailable();}
    finally {clearTimeout(timer);signal?.removeEventListener('abort', abort);}
  };
  const single = (data, name, target) => {
    const rows = data[name];
    if (!Array.isArray(rows) || rows.length > 1) fail();
    if (!rows.length) return null;
    const row = rows[0];
    if (!row || !same(row.id, target.id) || row.event_id !== target.event_id ||
      !same(row.user_uid, target.user_uid) || !same(row.installation_id, target.installation_id)) fail();
    return row;
  };
  return Object.freeze({
    async enabled({signal} = {}) {
      const data = await request(documents.enabled, {}, signal);
      const rows = data.notification_delivery_control_v2;
      if (!Array.isArray(rows) || rows.length !== 1 ||
        typeof rows[0]?.capture_enabled !== 'boolean' || typeof rows[0].dispatch_enabled !== 'boolean' ||
        (rows[0].dispatch_enabled && !rows[0].capture_enabled)) fail();
      return rows[0].dispatch_enabled;
    },
    async claim({worker, limit, signal}) {
      const data = await request(documents.claim, {worker, limit}, signal);
      const rows = data.claim_notification_targets_v2;
      if (!Array.isArray(rows) || rows.length > limit) fail();
      return rows;
    },
    async admit({target, registrationId, token, signal}) {
      const data = await request(documents.admit, {id: target.id, lease: target.lease_token,
        registration: registrationId, token}, signal);
      const row = single(data, 'admit_notification_target_v2', target);
      if (row && (row.status !== 'processing' || !same(row.lease_token, target.lease_token))) fail();
      return row !== null;
    },
    async finish({target, outcome, code, providerMessageId, signal}) {
      const data = await request(documents.finish, {id: target.id, lease: target.lease_token,
        outcome, error: code, provider: providerMessageId}, signal);
      const row = single(data, 'finish_notification_target_v2', target);
      if (row && (outcome === 'accepted' ? row.status !== 'accepted' || row.provider_message_id !== providerMessageId
        : outcome === 'retryable' ? !['pending', 'dead'].includes(row.status) : row.status !== 'cancelled')) fail();
      return row !== null;
    },
    async deactivate({target, registrationId, token, signal}) {
      const data = await request(documents.deactivate, {id: registrationId, uid: target.user_uid,
        installation: target.installation_id, token}, signal);
      const rows = data.deactivate_notification_registration_v2;
      if (!Array.isArray(rows) || rows.length > 1) fail();
      if (!rows.length) return false;
      const row = rows[0];
      if (!same(row?.id, registrationId) || !same(row.user_uid, target.user_uid) ||
        !same(row.installation_id, target.installation_id) || row.is_active !== false) fail();
      return true;
    },
  });
}

module.exports = {documents, createNotificationRepositoryV2};
