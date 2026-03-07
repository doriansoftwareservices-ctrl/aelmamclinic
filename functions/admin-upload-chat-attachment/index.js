// Use manual multipart builder (same pattern as subscription-proof) for max compatibility

const {
  readBody,
  resolveStorageUrl,
  adminSecret,
  resolveUserIdFromToken,
  extractBearer,
  safeBasename,
  parseChatIds,
  isSuperAdmin,
  getParticipantRole,
  messageBelongsToSender,
  ensureBucketExists,
} = require('../_shared/storage_utils');

const pick = (obj, keys, fallback = null) => {
  if (!obj || typeof obj !== 'object') return fallback;
  for (const k of keys) {
    const v = obj[k];
    if (v !== undefined && v !== null) return v;
  }
  return fallback;
};

module.exports = async (req, res) => {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: 'method-not-allowed' });
    }

    const body = await readBody(req);
    const filename = `${pick(body, ['filename', 'name', 'path'], '')}`.trim();
    const bucketId = `${pick(
      body,
      ['bucketId', 'bucket_id', 'bucket'],
      'chat-images',
    )}`.trim();
    const mimeType = `${pick(
      body,
      ['mimeType', 'mime_type'],
      'application/octet-stream',
    )}`.trim();
    const base64 = `${pick(body, ['base64', 'data'], '')}`.trim();
    const metadata =
      body.metadata && typeof body.metadata === 'object' ? body.metadata : {};

    if (!filename || !base64) {
      return res
        .status(400)
        .json({ error: 'bad-request', message: 'filename/base64 required' });
    }

    const token = extractBearer(req);
    const uid = await resolveUserIdFromToken(token);
    if (!uid) return res.status(401).json({ error: 'unauthorized' });

    const { conversationId, messageId } = parseChatIds({ filename, metadata });
    if (!conversationId) {
      return res.status(400).json({
        error: 'bad-request',
        message:
          'conversation_id missing (metadata.conversation_id or attachments/<conversationId>/...)',
      });
    }

    const sa = await isSuperAdmin(uid);
    let role = null;
    if (!sa) {
      role = await getParticipantRole(conversationId, uid);
      if (!role) {
        return res
          .status(403)
          .json({ error: 'forbidden', message: 'not a participant' });
      }
    }

    if (!sa && messageId) {
      const isSender = await messageBelongsToSender(
        messageId,
        uid,
        conversationId,
      );
      const r = `${role || ''}`.toLowerCase();
      const isConvAdmin = ['admin', 'owner', 'superadmin'].includes(r);
      if (!isSender && !isConvAdmin) {
        return res
          .status(403)
          .json({ error: 'forbidden', message: 'not sender/admin' });
      }
    }

    const bucketOk = await ensureBucketExists(bucketId);
    if (!bucketOk) {
      return res
        .status(400)
        .json({ error: 'bad-request', message: `bucket not found: ${bucketId}` });
    }

    const storageUrl = resolveStorageUrl();
    if (!storageUrl) {
      return res
        .status(500)
        .json({ error: 'internal', message: 'missing storage url' });
    }

    const buf = Buffer.from(base64, 'base64');
    const meta = {
      name: filename,
      bucketId,
      metadata: {
        ...metadata,
        conversation_id: metadata.conversation_id || conversationId,
        message_id: metadata.message_id || messageId,
        uploaded_by_user_id: uid,
      },
    };
    const metaJson = JSON.stringify(meta);
    const fields = {
      'bucket-id': bucketId,
      bucketId,
      'metadata[]': metaJson,
    };
    const multipart = buildMultipart({
      fieldName: 'file[]',
      filename: safeBasename(filename),
      contentType: mimeType || 'application/octet-stream',
      buffer: buf,
      fields,
    });

    const uploadResp = await postMultipart(
      `${storageUrl}/files`,
      {
        Authorization: `Bearer ${token}`,
        ...multipart.headers,
      },
      multipart.body,
    );

    let responsePayload = uploadResp.text;
    try {
      responsePayload = JSON.parse(uploadResp.text);
    } catch (_) {}
    const ok = uploadResp.status >= 200 && uploadResp.status < 300;
    if (!ok) {
      const details =
        typeof responsePayload === 'string'
          ? responsePayload
          : JSON.stringify(responsePayload ?? {});
      const detailed = `storage-upload-failed: status=${uploadResp.status} body=${details}`;
      return res.status(uploadResp.status || 500).json({
        error: detailed,
        message: detailed,
        status: uploadResp.status,
        body: responsePayload,
      });
    }

    return res.status(uploadResp.status).json(responsePayload);
  } catch (e) {
    return res
      .status(500)
      .json({ error: 'internal', message: `${e?.message || e}` });
  }
};

function buildMultipart({
  fieldName,
  filename,
  contentType,
  buffer,
  fields,
  extraFiles,
}) {
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
  if (Array.isArray(extraFiles)) {
    for (const part of extraFiles) {
      if (!part || !part.name || !part.buffer) continue;
      const partName = part.name;
      const partFilename = part.filename ?? '';
      const partType = part.contentType ?? 'application/octet-stream';
      push(`--${boundary}\r\n`);
      push(
        `Content-Disposition: form-data; name="${partName}"; filename="${partFilename}"\r\n`,
      );
      push(`Content-Type: ${partType}\r\n\r\n`);
      chunks.push(part.buffer);
      push('\r\n');
    }
  }
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
    const req = require('https').request(opts, (resp) => {
      let data = '';
      resp.on('data', (chunk) => {
        data += chunk;
      });
      resp.on('end', () => {
        resolve({ status: resp.statusCode || 0, text: data });
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
