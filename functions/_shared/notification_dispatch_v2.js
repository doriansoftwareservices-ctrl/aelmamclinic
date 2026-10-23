'use strict';

// Unwired v2 worker core. No credentials, HTTP endpoint, scheduler or provider
// is created on import. Enable only with the complete, native-tested protocol.
const {randomUUID} = require('node:crypto');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EVENT = /^nev2_[0-9a-f]{64}$/;
const kinds = ['new_patient', 'chat_message', 'plan_request', 'seat_request'];
const timeouts = Object.freeze({enabled: 5000, claim: 5000, authority: 24000,
  admit: 4000, send: 8000, deactivate: 4000, finish: 5000});
const uuid = value => typeof value === 'string' && UUID.test(value);
const same = (left, right) => typeof left === 'string' && typeof right === 'string' &&
  left.toLowerCase() === right.toLowerCase();

class NotificationDispatchUnavailable extends Error {
  constructor() {super('notification_dispatch_unavailable');this.code = 'notification_dispatch_unavailable';}
}
const unavailable = () => {throw new NotificationDispatchUnavailable();};

async function bounded(operation, milliseconds) {
  const controller = new AbortController();
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(() => operation(controller.signal)),
      new Promise((_, reject) => {
        timer = setTimeout(() => {controller.abort();reject(new NotificationDispatchUnavailable());}, milliseconds);
      }),
    ]);
  } catch (_) {throw new NotificationDispatchUnavailable();}
  finally {clearTimeout(timer);}
}

function snapshot(target) {
  const event = target?.delivery_event;
  if (!target || ![target.id, target.user_uid, target.token_id, target.installation_id,
    target.lease_token, target.ack_nonce].every(uuid) || target.status !== 'processing' ||
    !Number.isInteger(target.attempts) || target.attempts < 1 || target.attempts > 8 ||
    !event || !EVENT.test(event.event_id) || event.event_id !== target.event_id ||
    !uuid(event.source_id) || !kinds.includes(event.event_type) ||
    !Object.hasOwn(event, 'account_id') || (event.account_id !== null && !uuid(event.account_id))) unavailable();
  return Object.freeze({...target, delivery_event: Object.freeze({...event})});
}

function validateAuthority(target, authority) {
  const event = target.delivery_event;
  if (authority?.allowed !== true || !same(authority.recipientUid, target.user_uid) ||
    !same(authority.sourceId, event.source_id) || authority.kind !== event.event_type ||
    (event.account_id === null ? authority.accountId !== null : !same(authority.accountId, event.account_id)) ||
    !uuid(authority.registrationId) || typeof authority.transportToken !== 'string' ||
    !authority.transportToken.trim() || (event.event_type === 'chat_message' && !uuid(authority.conversationId))) unavailable();
}

function payload(target, authority) {
  return Object.freeze({notification_protocol: '2', event_id: target.event_id,
    target_id: target.id, ack_nonce: target.ack_nonce, recipient_uid: target.user_uid,
    installation_id: target.installation_id, account_id: authority.accountId ?? '',
    kind: authority.kind, source_id: authority.sourceId,
    ...(authority.conversationId ? {conversation_id: authority.conversationId} : {})});
}

async function dispatchNotificationBatchV2({repository, resolveAuthority, send,
  limit = 8, worker = randomUUID(), operationTimeouts = {}}) {
  if (!repository || !['enabled', 'claim', 'admit', 'finish', 'deactivate'].every(
    key => typeof repository[key] === 'function') || typeof resolveAuthority !== 'function' ||
    typeof send !== 'function' || !Number.isInteger(limit) || limit < 1 || limit > 20 || !uuid(worker)) unavailable();
  const budget = {...timeouts, ...operationTimeouts};
  if (Object.keys(budget).some(key => !Object.hasOwn(timeouts, key) ||
    !Number.isInteger(budget[key]) || budget[key] < 1 || budget[key] > timeouts[key])) unavailable();
  const invoke = (name, fn) => bounded(fn, budget[name]);
  const counts = {claimed: 0, providerAccepted: 0, recordedAccepted: 0,
    retryable: 0, cancelled: 0, fenced: 0, unconfirmed: 0};
  const enabled = await invoke('enabled', signal => repository.enabled({signal}));
  if (enabled === false) return {...counts, disabled: true};
  if (enabled !== true) unavailable();
  const claimed = await invoke('claim', signal => repository.claim({worker, limit, signal}));
  if (!Array.isArray(claimed) || claimed.length > limit) unavailable();
  // Validate the whole batch before any external effect.
  const targets = claimed.map(snapshot);
  if (new Set(targets.map(target => target.id.toLowerCase())).size !== targets.length) unavailable();
  counts.claimed = targets.length;
  const finish = async (target, outcome, code = null, providerMessageId = null) => {
    try {
      const saved = await invoke('finish', signal => repository.finish({target, outcome,
        code, providerMessageId, signal}));
      if (saved === false) counts.fenced++;
      else if (saved !== true) counts.unconfirmed++;
      else if (outcome === 'accepted') counts.recordedAccepted++;
      else counts[outcome]++;
    } catch (_) {counts.unconfirmed++;}
  };
  await Promise.all(targets.map(async target => {
    let authority;
    try {
      authority = await invoke('authority', signal => resolveAuthority(target, {signal}));
      if (authority?.allowed === false) {
        await finish(target, 'cancelled', 'authority_revoked');return;
      }
      validateAuthority(target, authority);
      authority = Object.freeze({...authority});
    } catch (_) {await finish(target, 'retryable', 'authority_unavailable');return;}
    try {
      // The repository MUST check the server clock, current lease and private
      // dispatch barrier immediately before send. False never means accepted.
      const admitted = await invoke('admit', signal => repository.admit({target,
        registrationId: authority.registrationId, token: authority.transportToken, signal}));
      if (admitted === false) {counts.fenced++;return;}
      if (admitted !== true) unavailable();
    } catch (_) {await finish(target, 'retryable', 'admission_unavailable');return;}
    let result;
    try {
      result = await invoke('send', signal => send({token: authority.transportToken,
        data: payload(target, authority), signal}));
    } catch (_) {await finish(target, 'retryable', 'provider_unavailable');return;}
    if (result?.outcome === 'accepted' && typeof result.providerMessageId === 'string' &&
      result.providerMessageId.length <= 512 && /^projects\/[^/\s]+\/messages\/\S+$/.test(result.providerMessageId)) {
      counts.providerAccepted++;
      await finish(target, 'accepted', null, result.providerMessageId);return;
    }
    if (result?.outcome === 'unregistered') {
      try {
        // Compare the exact UID, installation, registration ID AND token. An
        // invalid old token must never deactivate a concurrently rotated token.
        const cleaned = await invoke('deactivate', signal => repository.deactivate({target,
          registrationId: authority.registrationId, token: authority.transportToken, signal}));
        if (cleaned !== true && cleaned !== false) unavailable();
      } catch (_) {await finish(target, 'retryable', 'registration_cleanup_unavailable');return;}
      // Rotation may have committed during send. Re-resolve this installation
      // on retry instead of permanently cancelling its immutable destination.
      await finish(target, 'retryable', 'registration_unregistered');return;
    }
    await finish(target, 'retryable', 'provider_unavailable');
  }));
  return {...counts, disabled: false};
}

module.exports = {dispatchNotificationBatchV2, NotificationDispatchUnavailable};
