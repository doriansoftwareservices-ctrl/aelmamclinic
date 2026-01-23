const https = require('https');
const { URL } = require('url');

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

const LOG_PREFIX = '[admin-upload-chat-attachment]';

function decodeJwtPayload(authHeader) {
  if (!authHeader || !authHeader.startsWith('Bearer ')) return {};
  const token = authHeader.slice(7).trim();
  const parts = token.split('.');
  if (parts.length < 2) return {};
  try {
    let payloadB64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    while (payloadB64.length % 4 !== 0) payloadB64 += '=';
    const payload = Buffer.from(payloadB64, 'base64').toString('utf-8');
    return JSON.parse(payload);
  } catch (_) {
    return {};
  }
}

function buildMultipart({ fieldName, filename, contentType, buffer, fields }) {
  const boundary = `--------------------------${Date.now().toString(16)}${Math.random()
    .toString(16)
    .slice(2)}`;
  const chunks = [];
  const push = (s) => chunks.push(Buffer.from(s, 'utf8'));
  const pushField = (name, value) => {
    push(`--${boundary}\r\n`);
    push(`Content-Disposition: form-data; name="${name}"\r\n\r\n`);
    push(`${value}\r\n`);
  };
  if (fields && typeof fields === 'object') {
    for (const [k, v] of Object.entries(fields)) {
      if (v === undefined || v === null) continue;
      pushField(k, `${v}`);
    }
  }
  push(`--${boundary}\r\n`);
  push(
    `Content-Disposition: form-data; name="${fieldName}"; filename="${filename}"\r\n`,
  );
  push(`Content-Type: ${contentType}\r\n\r\n`);
  chunks.push(buffer);
  push('\r\n');
  push(`--${boundary}--\r\n`);
  const body = Buffer.concat(chunks);
  return {
    body,
    headers: {
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
      'Content-Length': String(body.length),
    },
  };
}

function postJson(url, headers, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const payload = JSON.stringify(body);
    const opts = {
      method: 'POST',
      hostname: target.hostname,
      port: target.port || 443,
      path: target.pathname + target.search,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
        ...headers,
      },
    };
    const req = https.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        resolve({ status: res.statusCode || 0, text: data });
      });
    });
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

function postMultipart(url, headers, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const opts = {
      method: 'POST',
      hostname: target.hostname,
      port: target.port || 443,
      path: target.pathname + target.search,
      headers,
    };
    const req = https.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        resolve({ status: res.statusCode || 0, text: data });
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function ensureChatParticipant(authHeader, conversationId) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
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
  const gqlRes = await postJson(
    gqlUrl,
    adminSecret
      ? { 'x-hasura-admin-secret': adminSecret }
      : { Authorization: authHeader },
    {
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
    },
  );
  if (gqlRes.status < 200 || gqlRes.status >= 300) {
    throw new Error(`Auth check failed: ${gqlRes.status} ${gqlRes.text}`);
  }
  let json = {};
  try {
    json = JSON.parse(gqlRes.text || '{}');
  } catch (_) {
    json = {};
  }
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
      console.error(
        `${LOG_PREFIX} missing storage config`,
        `storageUrl=${storageUrl ? 'set' : 'missing'}`,
        `adminSecret=${adminSecret ? 'set' : 'missing'}`,
      );
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
      const fields = { 'bucket-id': bucketId };
      if (includeMeta) {
        fields[useArrayFields ? 'metadata[]' : 'metadata'] = JSON.stringify(meta);
      }
      const fieldName = useArrayFields ? 'file[]' : 'file';
      const mp = buildMultipart({
        fieldName,
        filename: storageName,
        contentType: mimeType,
        buffer,
        fields,
      });

      const uploadRes = await postMultipart(
        `${storageUrl}/files`,
        { 'x-hasura-admin-secret': adminSecret, ...mp.headers },
        mp.body,
      );
      let responsePayload = uploadRes.text;
      try {
        responsePayload = JSON.parse(uploadRes.text || '{}');
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

    if (!uploadRes || uploadRes.status < 200 || uploadRes.status >= 300) {
      const status = uploadRes?.status || 500;
      res.status(status).json({
        ok: false,
        error: responsePayload?.error ?? responsePayload ?? 'Upload failed',
      });
      return;
    }

    res.status(uploadRes.status).json(responsePayload);
  } catch (err) {
    const status = err?.statusCode || 500;
    // Log full error for Nhost function logs.
    console.error(`${LOG_PREFIX} failed`, err);
    res.status(status).json({
      ok: false,
      error: err?.message ?? 'Failed',
    });
  }
};
