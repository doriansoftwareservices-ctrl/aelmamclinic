// Use manual multipart builder (same pattern as subscription-proof) for max compatibility

const {
  readBody,
  resolveStorageUrl,
  adminSecret,
  resolveUserIdFromToken,
  extractBearer,
  safeBasename,
  parseChatIds,
  getChatAccess,
  messageBelongsToSender,
  messageBelongsToConversation,
  ensureBucketExists,
  updateChatFileOwnership,
} = require('../_shared/storage_utils');

const pick = (obj, keys, fallback = null) => {
  if (!obj || typeof obj !== 'object') return fallback;
  for (const k of keys) {
    const v = obj[k];
    if (v !== undefined && v !== null) return v;
  }
  return fallback;
};

const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
const STORAGE_UPLOAD_TIMEOUT_MS = Number(
  process.env.STORAGE_UPLOAD_TIMEOUT_MS || 30000,
);
const ALLOWED_ATTACHMENT_BUCKETS = new Set(
  `${process.env.CHAT_ATTACHMENT_BUCKETS || 'chat-images,chat-attachments'}`
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean),
);
const ALLOWED_MIME_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'application/pdf',
  'text/plain',
]);
const MIME_BY_EXTENSION = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  gif: 'image/gif',
  pdf: 'application/pdf',
  txt: 'text/plain',
};

const extensionOf = (filename) => {
  const base = safeBasename(`${filename || ''}`).toLowerCase();
  const dot = base.lastIndexOf('.');
  return dot >= 0 ? base.slice(dot + 1) : '';
};

const normalizeBucketId = (value) => {
  const bucket = `${value || 'chat-images'}`.trim();
  return ALLOWED_ATTACHMENT_BUCKETS.has(bucket) ? bucket : null;
};

const sniffMimeType = (buffer) => {
  if (!Buffer.isBuffer(buffer) || buffer.length < 4) return null;
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return 'image/jpeg';
  }
  if (
    buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47
  ) {
    return 'image/png';
  }
  if (buffer.slice(0, 4).toString('ascii') === '%PDF') return 'application/pdf';
  if (
    buffer.length >= 12 &&
    buffer.slice(0, 4).toString('ascii') === 'RIFF' &&
    buffer.slice(8, 12).toString('ascii') === 'WEBP'
  ) {
    return 'image/webp';
  }
  if (buffer.slice(0, 3).toString('ascii') === 'GIF') return 'image/gif';
  return null;
};

const normalizeMimeType = ({ filename, requestedMimeType, buffer }) => {
  const ext = extensionOf(filename);
  const byExt = MIME_BY_EXTENSION[ext] || null;
  const requested = `${requestedMimeType || ''}`.split(';')[0].trim().toLowerCase();
  const sniffed = sniffMimeType(buffer);
  const mime = sniffed || byExt || requested;
  if (!mime || !ALLOWED_MIME_TYPES.has(mime)) return null;
  if (byExt && mime !== byExt && !(byExt === 'image/jpeg' && mime === 'image/jpeg')) {
    return null;
  }
  if (sniffed && byExt && sniffed !== byExt) return null;
  return mime;
};

const estimateBase64Bytes = (value) => {
  const normalized = `${value || ''}`.replace(/\s+/g, '');
  if (!normalized) return 0;
  const paddingMatch = normalized.match(/=+$/);
  const padding = paddingMatch ? paddingMatch[0].length : 0;
  return Math.floor((normalized.length * 3) / 4) - padding;
};

module.exports = async (req, res) => {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: 'method-not-allowed' });
    }

    const body = await readBody(req);
    const filename = `${pick(body, ['filename', 'name', 'path'], '')}`.trim();
    const requestedBucketId = pick(
      body,
      ['bucketId', 'bucket_id', 'bucket'],
      'chat-images',
    );
    const bucketId = normalizeBucketId(requestedBucketId);
    const requestedMimeType = pick(
      body,
      ['mimeType', 'mime_type'],
      'application/octet-stream',
    );
    let base64 = `${pick(body, ['base64', 'data'], '')}`.trim();
    const metadata =
      body.metadata && typeof body.metadata === 'object' ? body.metadata : {};

    if (!filename || !base64) {
      return res
        .status(400)
        .json({ error: 'bad-request', message: 'filename/base64 required' });
    }
    if (!bucketId) {
      return res.status(400).json({
        error: 'bad-request',
        message: 'bucket is not allowed for chat attachments',
      });
    }
    if (!extensionOf(filename)) {
      return res.status(400).json({
        error: 'bad-request',
        message: 'file extension is required',
      });
    }

    if (base64.startsWith('data:')) {
      const comma = base64.indexOf(',');
      base64 = comma >= 0 ? base64.slice(comma + 1).trim() : '';
    }

    const estimatedBytes = estimateBase64Bytes(base64);
    if (estimatedBytes > MAX_ATTACHMENT_BYTES) {
      return res
        .status(413)
        .json({ error: 'file_too_large', message: 'attachment exceeds max size' });
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

    if (!messageId) {
      return res.status(400).json({
        error: 'bad-request',
        message: 'message_id is required for chat attachments',
      });
    }

    const access = await getChatAccess(conversationId, uid);
    if (!access.allowed || !access.accountId) {
      return res.status(access.accountFrozen ? 423 : 403).json({
        error: access.accountFrozen ? 'account_frozen' : 'forbidden',
        message: 'chat attachment access denied',
      });
    }
    const sa = access.isSuperAdmin;
    const role = access.participantRole;

    const messageExists = await messageBelongsToConversation(
      messageId,
      conversationId,
    );
    if (!messageExists) {
      return res.status(404).json({
        error: 'message_not_found',
        message: 'chat message does not belong to the conversation',
      });
    }

    if (!sa) {
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
    if (buf.length > MAX_ATTACHMENT_BYTES) {
      return res
        .status(413)
        .json({ error: 'file_too_large', message: 'attachment exceeds max size' });
    }
    const mimeType = normalizeMimeType({
      filename,
      requestedMimeType,
      buffer: buf,
    });
    if (!mimeType) {
      return res.status(415).json({
        error: 'unsupported_media_type',
        message: 'attachment type is not allowed or does not match its extension',
      });
    }
    const meta = {
      name: `attachments/${conversationId}/${messageId}/${safeBasename(filename)}`,
      bucketId,
      metadata: {
        account_id: access.accountId,
        conversation_id: conversationId,
        message_id: messageId,
        uploaded_by_user_id: uid,
        security_state: 'active',
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

    const secret = adminSecret();
    if (!secret) {
      return res.status(503).json({
        error: 'storage_unavailable',
        message: 'chat attachment storage is unavailable',
      });
    }

    const uploadResp = await postMultipart(
      `${storageUrl}/files`,
      {
        'x-hasura-admin-secret': secret,
        ...multipart.headers,
      },
      multipart.body,
      STORAGE_UPLOAD_TIMEOUT_MS,
    );

    let responsePayload = uploadResp.text;
    try {
      responsePayload = JSON.parse(uploadResp.text);
    } catch (_) {}
    const ok = uploadResp.status >= 200 && uploadResp.status < 300;
    if (!ok) {
      console.warn('chat attachment storage upload failed', {
        status: uploadResp.status,
      });
      return res.status(uploadResp.status >= 400 ? uploadResp.status : 502).json({
        error: 'storage_upload_failed',
        message: 'chat attachment upload failed',
      });
    }

    const uploaded = extractUploadedFile(responsePayload);
    const fileId = `${uploaded?.id || ''}`.trim();
    if (!fileId) {
      return res.status(502).json({
        error: 'storage_contract_invalid',
        message: 'storage returned an invalid upload response',
      });
    }
    const ownershipLinked = await updateChatFileOwnership({
      fileId,
      bucketId,
      fileName: `${uploaded?.name || meta.name}`.trim(),
      accountId: access.accountId,
      conversationId,
      messageId,
      uploadedByUserId: uid,
    });
    if (!ownershipLinked) {
      await deleteStorageFile(storageUrl, fileId, secret).catch(() => null);
      return res.status(502).json({
        error: 'attachment_ownership_failed',
        message: 'chat attachment ownership could not be established',
      });
    }

    return res.status(uploadResp.status).json(responsePayload);
  } catch (e) {
    console.error('chat attachment upload failed', {
      error: `${e?.code || e?.name || 'internal'}`,
    });
    return res.status(500).json({
      error: 'internal',
      message: 'chat attachment upload failed',
    });
  }
};

function extractUploadedFile(payload) {
  if (!payload || typeof payload !== 'object') return null;
  if (payload.id) return payload;
  const rows = payload.processedFiles || payload.processed_files || payload.files;
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function deleteStorageFile(storageUrl, fileId, secret) {
  await fetch(`${storageUrl}/files/${encodeURIComponent(fileId)}`, {
    method: 'DELETE',
    headers: { 'x-hasura-admin-secret': secret },
  });
}

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

function postMultipart(url, headers, body, timeoutMs) {
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
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`storage upload timeout after ${timeoutMs}ms`));
    });
    req.write(body);
    req.end();
  });
}