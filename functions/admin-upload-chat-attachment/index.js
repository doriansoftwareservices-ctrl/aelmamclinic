const readBody = (req) =>
  new Promise((resolve) => {
    if (req.body && typeof req.body === 'object') {
      resolve(req.body);
      return;
    }
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
    });
    req.on('end', () => {
      if (!data) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(data));
      } catch (_) {
        resolve({});
      }
    });
  });

const resolveStorageUrl = () => {
  const candidates = [
    process.env.NHOST_STORAGE_URL,
    process.env.NHOST_BACKEND_URL,
    process.env.NHOST_GRAPHQL_URL,
  ];
  for (const raw of candidates) {
    if (!raw) continue;
    if (!raw.includes('nhost.run')) continue;
    let url = raw.replace(/\/+$/, '');
    url = url
      .replace('.graphql.', '.storage.')
      .replace('.functions.', '.storage.')
      .replace('.auth.', '.storage.');
    url = url
      .replace(/\/v1\/graphql$/i, '')
      .replace(/\/graphql$/i, '')
      .replace(/\/v1$/i, '');
    url = `${url}/v1`;
    return url;
  }
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.storage.${region}.nhost.run/v1`;
  }
  return null;
};

function decodeJwtPayload(authHeader) {
  if (!authHeader || !authHeader.startsWith('Bearer ')) return {};
  const token = authHeader.slice(7).trim();
  const parts = token.split('.');
  if (parts.length < 2) return {};
  try {
    const payload = Buffer.from(parts[1], 'base64').toString('utf-8');
    return JSON.parse(payload);
  } catch (_) {
    return {};
  }
}

async function ensureChatParticipant(authHeader, conversationId) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const payload = decodeJwtPayload(authHeader);
  const claims = payload['https://hasura.io/jwt/claims'] || {};
  const uid =
    claims['x-hasura-user-id'] ||
    payload['x-hasura-user-id'] ||
    payload.sub;
  if (!uid) {
    const err = new Error('missing user id');
    err.statusCode = 401;
    throw err;
  }
  const res = await fetch(gqlUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader,
    },
    body: JSON.stringify({
      query: `
        query ChatAttachmentUploadAuth($cid: uuid!, $uid: uuid!) {
          fn_is_super_admin_gql { is_super_admin }
          chat_participants(
            where: { conversation_id: { _eq: $cid }, user_uid: { _eq: $uid } }
            limit: 1
          ) {
            conversation_id
          }
        }
      `,
      variables: { cid: conversationId, uid },
    }),
  });
  if (!res.ok) {
    throw new Error(`Auth check failed: ${res.status}`);
  }
  const json = await res.json();
  if (json.errors?.length) {
    throw new Error(json.errors.map((e) => e.message).join(' | '));
  }
  const rows = json.data?.fn_is_super_admin_gql;
  const isSuper =
    Array.isArray(rows) && rows.length > 0 && rows[0]?.is_super_admin === true;
  if (isSuper) return { isSuper: true };
  const parts = json.data?.chat_participants;
  if (Array.isArray(parts) && parts.length > 0) {
    return { isSuper: false };
  }
  const err = new Error('forbidden');
  err.statusCode = 403;
  throw err;
}

module.exports = async function handler(req, res) {
  try {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method not allowed' });
      return;
    }
    const authHeader = req.headers?.authorization;
    if (!authHeader) {
      res.status(401).json({ ok: false, error: 'Missing authorization' });
      return;
    }

    const body = await readBody(req);
    const payload =
      body && typeof body === 'object' && body.input && typeof body.input === 'object'
        ? body.input
        : body;
    const filename = `${payload?.filename ?? ''}`.trim() || 'attachment';
    const conversationId = `${payload?.conversationId ?? payload?.conversation_id ?? ''}`.trim();
    const messageId = `${payload?.messageId ?? payload?.message_id ?? ''}`.trim();
    let base64 = `${payload?.base64 ?? ''}`.trim();
    if (base64.startsWith('data:')) {
      const comma = base64.indexOf(',');
      base64 = comma >= 0 ? base64.slice(comma + 1).trim() : '';
    }
    const mimeType =
      `${payload?.mimeType ?? 'application/octet-stream'}`.trim() ||
      'application/octet-stream';

    if (!conversationId) {
      res.status(400).json({ ok: false, error: 'Missing conversationId' });
      return;
    }
    if (!base64) {
      res.status(400).json({ ok: false, error: 'Missing base64 payload' });
      return;
    }

    await ensureChatParticipant(authHeader, conversationId);

    const maxBytes = 20 * 1024 * 1024;
    const buffer = Buffer.from(base64, 'base64');
    if (buffer.length > maxBytes) {
      res.status(413).json({ ok: false, error: 'File too large' });
      return;
    }

    const storageUrl = resolveStorageUrl();
    const adminSecret =
      process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
    if (!storageUrl || !adminSecret) {
      res.status(500).json({ ok: false, error: 'Missing storage config' });
      return;
    }

    const bucketId = 'chat-attachments';
    const safeName = filename.replace(/^[\/\\]+/, '');
    const storageName = messageId
      ? `attachments/${conversationId}/${messageId}/${safeName}`
      : `attachments/${conversationId}/${safeName}`;
    const meta = {
      name: storageName,
      metadata: {
        conversation_id: conversationId,
        message_id: messageId || null,
      },
    };

    const tryUpload = async (useArrayFields, includeMeta) => {
      const form = new FormData();
      form.append('bucket-id', bucketId);
      if (useArrayFields) {
        form.append('file[]', new Blob([buffer], { type: mimeType }), storageName);
        if (includeMeta) form.append('metadata[]', JSON.stringify(meta));
      } else {
        form.append('file', new Blob([buffer], { type: mimeType }), storageName);
        if (includeMeta) form.append('metadata', JSON.stringify(meta));
      }

      const uploadRes = await fetch(`${storageUrl}/files`, {
        method: 'POST',
        headers: { 'x-hasura-admin-secret': adminSecret },
        body: form,
      });

      const text = await uploadRes.text();
      let responsePayload = text;
      try {
        responsePayload = JSON.parse(text);
      } catch (_) {}
      return { uploadRes, responsePayload };
    };

    const attempts = [
      { arrayFields: false, includeMeta: true },
      { arrayFields: true, includeMeta: true },
      { arrayFields: false, includeMeta: false },
      { arrayFields: true, includeMeta: false },
    ];
    let uploadRes;
    let responsePayload;
    for (const attempt of attempts) {
      ({ uploadRes, responsePayload } = await tryUpload(
        attempt.arrayFields,
        attempt.includeMeta,
      ));
      if (uploadRes.ok) break;
    }

    if (!uploadRes || !uploadRes.ok) {
      res.status(uploadRes.status).json({
        ok: false,
        error: responsePayload?.error ?? responsePayload ?? 'Upload failed',
      });
      return;
    }

    res.status(uploadRes.status).json(responsePayload);
  } catch (err) {
    const status = err?.statusCode || 500;
    // Log full error for Nhost function logs.
    console.error('admin-upload-chat-attachment failed', err);
    res.status(status).json({
      ok: false,
      error: err?.message ?? 'Failed',
    });
  }
};
