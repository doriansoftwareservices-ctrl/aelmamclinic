'use strict';

// Unpublished notification-v2 building block. Existing handlers do not import
// this module. It reads current authority and never sends or acknowledges FCM.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const documents = Object.freeze({
  identity: `query NotificationRecipientIdentity($uid: uuid!, $token: uuid!) {
    user(id: $uid) { id disabled }
    push_device_tokens_by_pk(id: $token) {
      id user_uid account_id is_active platform token locale_code
    }
    super_admins(where: {user_uid: {_eq: $uid}, disabled: {_eq: false}}, limit: 1) { user_uid }
  }`,
  installation: `query NotificationRecipientInstallation($uid: uuid!, $installation: uuid!) {
    user(id: $uid) { id disabled }
    push_device_tokens(where: {user_uid: {_eq: $uid}, installation_id: {_eq: $installation},
      delivery_protocol: {_eq: 2}, is_active: {_eq: true}}, limit: 2) {
      id user_uid account_id is_active platform token locale_code installation_id delivery_protocol
    }
    super_admins(where: {user_uid: {_eq: $uid}, disabled: {_eq: false}}, limit: 1) { user_uid }
  }`,
  patient: `query NotificationPatient($id: uuid!) {
    patients(where: {id: {_eq: $id}, is_deleted: {_eq: false}}, limit: 1) {
      id account_id doctor_id
    }
  }`,
  doctor: `query NotificationAssignedDoctor($id: uuid!) {
    doctors(where: {id: {_eq: $id}, is_deleted: {_eq: false}}, limit: 1) {
      id account_id user_uid
    }
  }`,
  message: `query NotificationMessage($id: uuid!) {
    chat_messages(where: {id: {_eq: $id}, is_deleted: {_eq: false},
      _or: [{deleted: {_eq: false}}, {deleted: {_is_null: true}}]}, limit: 1) {
      id account_id conversation_id sender_uid
    }
  }`,
  participant: `query NotificationParticipant($cid: uuid!, $uid: uuid!) {
    chat_participants(where: {
      conversation_id: {_eq: $cid}, user_uid: {_eq: $uid},
      _or: [{is_deleted: {_eq: false}}, {is_deleted: {_is_null: true}}]
    }, limit: 1) { user_uid muted archived blocked }
  }`,
  plan: `query NotificationPlanRequest($id: uuid!) {
    subscription_requests(where: {id: {_eq: $id}}, limit: 1) {
      id account_id status plan_code
    }
  }`,
  seat: `query NotificationSeatRequest($id: uuid!) {
    employee_seat_requests(where: {id: {_eq: $id}}, limit: 1) {
      id account_id status seat_kind
    }
  }`,
});

class NotificationAuthorityUnavailable extends Error {
  constructor() {
    super('notification_authority_unavailable');
    this.name = 'NotificationAuthorityUnavailable';
    this.code = 'notification_authority_unavailable';
    this.retryable = true;
  }
}

const fail = () => { throw new NotificationAuthorityUnavailable(); };
const denied = reason => ({allowed: false, reason});
const uuid = value => typeof value === 'string' && UUID.test(value);
const same = (left, right) => typeof left === 'string' && typeof right === 'string' &&
  left.toLowerCase() === right.toLowerCase();

// Each read has immutable actor headers. A permission/schema/transport failure
// never falls back to an unrestricted admin read of the protected resource.
function createNotificationAuthorityQuery({url, adminSecret, fetchImpl = globalThis.fetch,
  timeoutMs = 8000}) {
  if (typeof url !== 'string' || !/^https?:\/\//.test(url) ||
      !url.endsWith('/v1/graphql') || typeof adminSecret !== 'string' ||
      !adminSecret || typeof fetchImpl !== 'function' ||
      !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 15000) fail();
  return async ({document, variables = {}, actor = null}) => {
    if (typeof document !== 'string' || !/^\s*query\b/.test(document)) fail();
    const headers = {'Content-Type': 'application/json',
      'x-hasura-admin-secret': adminSecret};
    if (actor != null) {
      if (!uuid(actor.uid) || !['user', 'superadmin'].includes(actor.role)) fail();
      headers['x-hasura-user-id'] = actor.uid;
      headers['x-hasura-role'] = actor.role;
    }
    const controller = new AbortController();
    let timer;
    try {
      const operation = (async () => {
        const response = await fetchImpl(url, {method: 'POST',
          headers: Object.freeze(headers), signal: controller.signal,
          body: JSON.stringify({query: document, variables})});
        const result = await response.json();
        if (!response.ok || result.errors || !result.data ||
            typeof result.data !== 'object' || Array.isArray(result.data)) fail();
        return result.data;
      })();
      return await Promise.race([operation, new Promise((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new NotificationAuthorityUnavailable());
        }, timeoutMs);
      })]);
    } catch (_) {
      // Do not include an upstream body, URL, token, patient or JWT in errors.
      throw new NotificationAuthorityUnavailable();
    } finally {
      clearTimeout(timer);
    }
  };
}

function one(rows, id) {
  if (!Array.isArray(rows) || rows.length > 1) fail();
  if (!rows.length) return null;
  if (!rows[0] || !same(rows[0].id, id)) fail();
  return rows[0];
}

async function resolveNotificationAuthority(target, {query}) {
  const event = target?.delivery_event;
  if (typeof query !== 'function' || !uuid(target?.user_uid) ||
      !uuid(target?.token_id) || !event || !uuid(event.source_id) ||
      !Object.hasOwn(event, 'account_id') ||
      (event.account_id !== null && !uuid(event.account_id)) ||
      !['new_patient', 'chat_message', 'plan_request', 'seat_request'].includes(event.event_type)) fail();
  const uid = target.user_uid;
  const installation = target.installation_id;
  if (installation != null && !uuid(installation)) fail();
  const read = async (document, variables, actor = null) => {
    try {
      const result = await query({document, variables,
        actor: actor == null ? null : Object.freeze({...actor})});
      if (!result || typeof result !== 'object' || Array.isArray(result)) fail();
      return result;
    } catch (_) {
      throw new NotificationAuthorityUnavailable();
    }
  };
  const identity = installation == null
    ? await read(documents.identity, {uid, token: target.token_id})
    : await read(documents.installation, {uid, installation});
  const user = identity.user;
  if (user === null) return denied('recipient_unavailable');
  if (!user || !same(user.id, uid) || typeof user.disabled !== 'boolean' ||
      !Array.isArray(identity.super_admins) ||
      identity.super_admins.some(row => !same(row?.user_uid, uid))) fail();
  if (user.disabled) return denied('recipient_disabled');
  let registration;
  if (installation == null) registration = identity.push_device_tokens_by_pk;
  else {
    if (!Array.isArray(identity.push_device_tokens) || identity.push_device_tokens.length > 1) fail();
    registration = identity.push_device_tokens[0] ?? null;
  }
  if (registration === null) return denied('registration_unavailable');
  if (!registration || !uuid(registration.id) ||
      (installation == null && !same(registration.id, target.token_id)) ||
      (installation != null && (!same(registration.installation_id, installation) ||
        registration.delivery_protocol !== 2)) ||
      typeof registration.is_active !== 'boolean') fail();
  if (!same(registration.user_uid, uid) || !registration.is_active ||
      typeof registration.token !== 'string' || !registration.token.trim()) {
    return denied('registration_inactive_or_rebound');
  }
  if (!['android', 'ios'].includes(registration.platform) ||
      (installation != null && registration.platform !== 'android')) {
    return denied('unsupported_push_platform');
  }
  if (!Object.hasOwn(registration, 'account_id') ||
      (registration.account_id !== null && !uuid(registration.account_id))) fail();
  if (event.account_id !== null && ['new_patient', 'chat_message'].includes(event.event_type) &&
      !same(registration.account_id, event.account_id)) return denied('registration_scope_changed');
  const isAdmin = identity.super_admins.length > 0;
  const actor = {uid, role: isAdmin ? 'superadmin' : 'user'};
  const hasCurrentScope = row => {
    if (!Object.hasOwn(row, 'account_id') ||
        (row.account_id !== null && !uuid(row.account_id))) fail();
    return row.account_id === null ? event.account_id === null : same(row.account_id, event.account_id);
  };
  let source;
  let conversationId;
  if (event.event_type === 'new_patient') {
    const data = await read(documents.patient, {id: event.source_id}, actor);
    source = one(data.patients, event.source_id);
    if (!source) return denied('source_not_visible');
    if (!hasCurrentScope(source)) return denied('source_scope_changed');
    if (!Object.hasOwn(source, 'doctor_id') ||
        (source.doctor_id !== null && !uuid(source.doctor_id))) fail();
    if (source.doctor_id === null) return denied('doctor_not_assigned');
    const assigned = await read(documents.doctor, {id: source.doctor_id});
    const doctor = one(assigned.doctors, source.doctor_id);
    if (doctor && (!Object.hasOwn(doctor, 'account_id') ||
        !Object.hasOwn(doctor, 'user_uid'))) fail();
    if (!doctor || !same(doctor.user_uid, uid) ||
        !same(doctor.account_id, source.account_id)) return denied('assignment_changed');
  } else if (event.event_type === 'chat_message') {
    const data = await read(documents.message, {id: event.source_id}, actor);
    source = one(data.chat_messages, event.source_id);
    if (!source) return denied('source_not_visible');
    if (!uuid(source.conversation_id) || !uuid(source.sender_uid)) fail();
    if (same(source.sender_uid, uid)) return denied('self_message');
    const participants = await read(documents.participant,
      {cid: source.conversation_id, uid});
    if (!Array.isArray(participants.chat_participants) ||
        participants.chat_participants.some(row => !same(row?.user_uid, uid))) fail();
    if (!participants.chat_participants.length) return denied('participant_removed');
    const participant = participants.chat_participants[0];
    if (![true, false, null].includes(participant.muted) ||
        ![true, false, null].includes(participant.archived) ||
        ![true, false, null].includes(participant.blocked)) fail();
    if (participant.muted === true || participant.archived === true ||
        participant.blocked === true) return denied('participant_notifications_disabled');
    conversationId = source.conversation_id;
  } else {
    if (!isAdmin) return denied('active_superadmin_required');
    const seat = event.event_type === 'seat_request';
    const data = await read(seat ? documents.seat : documents.plan,
      {id: event.source_id}, actor);
    source = one(seat ? data.employee_seat_requests : data.subscription_requests,
      event.source_id);
    if (!source) return denied('source_not_visible');
    if (typeof source.status !== 'string') fail();
    if (seat ? source.status !== 'submitted' : source.status !== 'pending') {
      return denied('request_already_handled');
    }
  }
  if (!hasCurrentScope(source)) return denied('source_scope_changed');
  return {allowed: true, recipientUid: uid, accountId: source.account_id,
    sourceId: source.id, kind: event.event_type,
    ...(conversationId ? {conversationId} : {}),
    locale: registration.locale_code === 'en' ? 'en' : 'ar',
    // Server-private; callers must never put this object in an HTTP response/log.
    transportToken: registration.token, registrationId: registration.id};
}

module.exports = {documents, NotificationAuthorityUnavailable,
  createNotificationAuthorityQuery, resolveNotificationAuthority};
