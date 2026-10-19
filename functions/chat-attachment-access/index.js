const crypto = require('crypto');
const {
  readBody,
  resolveStorageUrl,
  adminSecret,
  resolveUserIdFromToken,
  extractBearer,
  getChatAccess,
  deleteChatFileOwnership,
  runSql,
} = require('../_shared/storage_utils');

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

const fail = (res, status, code, correlationId) =>
  res.status(status).json({
    ok: false,
    error: code,
    correlation_id: correlationId,
  });

async function findFile(body, allowDeletedMessage = false) {
  const fileId = `${body.file_id || body.fileId || ''}`.trim();
  const bucket = `${body.bucket || body.bucket_id || body.bucketId || ''}`.trim();
  const path = `${body.path || body.name || ''}`.trim();
  let predicate;
  if (uuidPattern.test(fileId)) {
    predicate = `sf.id = '${escapeLiteral(fileId)}'::uuid`;
  } else if (
    ['chat-images', 'chat-attachments'].includes(bucket) &&
    path
  ) {
    predicate = `sf.bucket_id = '${escapeLiteral(bucket)}' and sf.name = '${escapeLiteral(path)}'`;
  } else {
    return null;
  }

  const json = await runSql(
    `with registered as (
       select sf.id::text,
              sf.bucket_id,
              sf.name,
              o.account_id::text,
              o.conversation_id::text,
              o.message_id::text,
              coalesce(o.uploaded_by_user_id, sf.uploaded_by_user_id)::text,
              o.security_state
         from storage.files sf
         join public.chat_attachment_file_ownership o
           on (o.file_id is not null and o.file_id = sf.id)
           or (o.file_id is null and o.bucket_id = sf.bucket_id and o.file_name = sf.name)
         join public.chat_messages owned_message
           on owned_message.id = o.message_id
          and owned_message.conversation_id = o.conversation_id
         join public.chat_conversations owned_conversation
           on owned_conversation.id = o.conversation_id
          and owned_conversation.account_id is not distinct from o.account_id
        where ${predicate}
          and sf.bucket_id in ('chat-images', 'chat-attachments')
          and o.security_state = 'active'
          and (${allowDeletedMessage ? 'true' : `coalesce(owned_message.is_deleted, false) = false
          and coalesce(owned_message.deleted, false) = false`})
       limit 1
     ), legacy as (
       select sf.id::text,
              sf.bucket_id,
              sf.name,
              c.account_id::text,
              m.conversation_id::text,
              a.message_id::text,
              coalesce(sf.uploaded_by_user_id, m.sender_uid)::text,
              'active'::text
         from storage.files sf
         join public.chat_attachments a
           on a.bucket = sf.bucket_id
          and (a.path = sf.id::text or a.path = sf.name)
         join public.chat_messages m on m.id = a.message_id
         join public.chat_conversations c on c.id = m.conversation_id
        where ${predicate}
          and sf.bucket_id in ('chat-images', 'chat-attachments')
          and c.account_id is not null
          and (a.account_id is null or a.account_id = c.account_id)
          and coalesce(a.is_deleted, false) = false
          and coalesce(m.is_deleted, false) = false
          and coalesce(m.deleted, false) = false
          and not exists (
            select 1 from public.chat_attachment_file_ownership existing
            where existing.file_id = sf.id
               or (existing.bucket_id = sf.bucket_id and existing.file_name = sf.name)
          )
       limit 1
     )
     select * from registered
     union all
     select * from legacy
     limit 1;`,
    true,
  );
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  if (!row) return null;
  return {
    id: row[0],
    bucketId: row[1],
    name: row[2],
    accountId: row[3],
    conversationId: row[4],
    messageId: row[5],
    uploadedByUserId: row[6],
    securityState: row[7],
  };
}

async function createSignedUrl(storageUrl, fileId, secret) {
  const response = await fetch(
    `${storageUrl}/files/${encodeURIComponent(fileId)}/presignedurl`,
    {
      method: 'GET',
      headers: { 'x-hasura-admin-secret': secret },
    },
  );
  if (!response.ok) return null;
  const payload = await response.json();
  const url = `${payload.url || ''}`.trim();
  const expiration = Number(payload.expiration);
  if (!url || !Number.isFinite(expiration) || expiration < 1) return null;
  // Nhost signs for the bucket's configured duration, not a POST body TTL.
  return { url, expiresIn: Math.floor(expiration) };
}

module.exports = async (req, res) => {
  const correlationId = crypto.randomUUID();
  try {
    if (req.method !== 'POST') {
      return fail(res, 405, 'method_not_allowed', correlationId);
    }
    const token = extractBearer(req);
    const uid = await resolveUserIdFromToken(token);
    if (!uid) return fail(res, 401, 'unauthorized', correlationId);

    const body = await readBody(req);
    const action = `${body.action || 'sign'}`.trim().toLowerCase();
    if (!['sign', 'resolve', 'delete'].includes(action)) {
      return fail(res, 400, 'invalid_action', correlationId);
    }
    const file = await findFile(body, action === 'delete');
    if (!file || file.securityState !== 'active' || !file.conversationId) {
      return fail(res, 404, 'attachment_not_found', correlationId);
    }
    const access = await getChatAccess(file.conversationId, uid);
    if (
      !access.allowed ||
      access.accountId !== file.accountId
    ) {
      return fail(
        res,
        access.accountFrozen ? 423 : 403,
        access.accountFrozen ? 'account_frozen' : 'forbidden',
        correlationId,
      );
    }

    if (action === 'resolve') {
      return res.status(200).json({
        ok: true,
        file_id: file.id,
        correlation_id: correlationId,
      });
    }

    const secret = adminSecret();
    const storageUrl = resolveStorageUrl();
    if (!secret || !storageUrl) {
      return fail(res, 503, 'storage_unavailable', correlationId);
    }

    if (action === 'delete') {
      const role = `${access.participantRole || ''}`.toLowerCase();
      const canDelete =
        access.isSuperAdmin ||
        file.uploadedByUserId === uid ||
        (access.accountId !== null && ['owner', 'admin'].includes(role));
      if (!canDelete) return fail(res, 403, 'delete_forbidden', correlationId);
      const response = await fetch(
        `${storageUrl}/files/${encodeURIComponent(file.id)}`,
        {
          method: 'DELETE',
          headers: { 'x-hasura-admin-secret': secret },
        },
      );
      if (!response.ok) {
        return fail(res, 502, 'storage_delete_failed', correlationId);
      }
      await deleteChatFileOwnership(file.id).catch((error) => {
        console.warn('chat attachment ownership cleanup failed', {
          correlation_id: correlationId,
          error: `${error?.code || error?.name || 'internal'}`,
        });
      });
      return res.status(200).json({ ok: true, correlation_id: correlationId });
    }

    const signed = await createSignedUrl(storageUrl, file.id, secret);
    if (!signed) {
      return fail(res, 502, 'storage_sign_failed', correlationId);
    }
    return res.status(200).json({
      ok: true,
      file_id: file.id,
      signed_url: signed.url,
      expires_in: signed.expiresIn,
      correlation_id: correlationId,
    });
  } catch (error) {
    console.error('chat attachment access failed', {
      correlation_id: correlationId,
      error: `${error?.code || error?.name || 'internal'}`,
    });
    return fail(res, 500, 'internal_error', correlationId);
  }
};
