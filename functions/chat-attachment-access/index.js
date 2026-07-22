const crypto = require('crypto');
const {
  readBody,
  resolveStorageUrl,
  adminSecret,
  resolveUserIdFromToken,
  extractBearer,
  getChatAccess,
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

async function findFile(body) {
  const fileId = `${body.file_id || body.fileId || ''}`.trim();
  const bucket = `${body.bucket || body.bucket_id || body.bucketId || ''}`.trim();
  const path = `${body.path || body.name || ''}`.trim();
  let predicate;
  if (uuidPattern.test(fileId)) {
    predicate = `id = '${escapeLiteral(fileId)}'::uuid`;
  } else if (bucket && path) {
    predicate = `bucket_id = '${escapeLiteral(bucket)}' and name = '${escapeLiteral(path)}'`;
  } else {
    return null;
  }
  const json = await runSql(
    `select id::text, bucket_id, name, account_id::text,
            conversation_id::text, attachment_message_id::text,
            uploaded_by_user_id::text, security_state
       from storage.files
      where ${predicate}
        and bucket_id in ('chat-images', 'chat-attachments')
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

async function createSignedUrl(storageUrl, fileId, ttl, secret) {
  const endpoints = [
    `${storageUrl}/files/${encodeURIComponent(fileId)}/presigned-url`,
    `${storageUrl}/files/${encodeURIComponent(fileId)}/presigned`,
  ];
  for (const endpoint of endpoints) {
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-hasura-admin-secret': secret,
      },
      body: JSON.stringify({ expiresIn: ttl }),
    });
    if (!response.ok) continue;
    const payload = await response.json();
    const value =
      payload.url ||
      payload.signedUrl ||
      payload.presignedUrl ||
      payload.presigned_url;
    if (`${value || ''}`.trim()) return `${value}`;
  }
  return null;
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
    const file = await findFile(body);
    if (!file || file.securityState !== 'active' || !file.conversationId) {
      return fail(res, 404, 'attachment_not_found', correlationId);
    }
    const access = await getChatAccess(file.conversationId, uid);
    if (
      !access.allowed ||
      !access.accountId ||
      access.accountId !== file.accountId
    ) {
      return fail(
        res,
        access.accountFrozen ? 423 : 403,
        access.accountFrozen ? 'account_frozen' : 'forbidden',
        correlationId,
      );
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
        ['owner', 'admin'].includes(role);
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
      return res.status(200).json({ ok: true, correlation_id: correlationId });
    }

    const requestedTtl = Number(body.expires_in || body.expiresIn || 300);
    const ttl = Math.max(60, Math.min(900, Number.isFinite(requestedTtl) ? requestedTtl : 300));
    const signedUrl = await createSignedUrl(storageUrl, file.id, ttl, secret);
    if (!signedUrl) {
      return fail(res, 502, 'storage_sign_failed', correlationId);
    }
    return res.status(200).json({
      ok: true,
      file_id: file.id,
      signed_url: signedUrl,
      expires_in: ttl,
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
