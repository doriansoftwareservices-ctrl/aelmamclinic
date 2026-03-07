// Compatibility for Nhost Functions runtime (ensures fetch/FormData/Blob exist)
let _fetch = globalThis.fetch;
let _FormData = globalThis.FormData;
let _Blob = globalThis.Blob;
let _File = globalThis.File;

try {
  if (!_fetch || !_FormData || !_Blob || !_File) {
    const undici = require('undici');
    _fetch = _fetch || undici.fetch;
    _FormData = _FormData || undici.FormData;
    _Blob = _Blob || undici.Blob;
    _File = _File || undici.File;
  }
} catch (_) {}

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
      'chat-attachments',
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
    const secret = adminSecret();
    if (!storageUrl || !secret) {
      return res
        .status(500)
        .json({ error: 'internal', message: 'missing storage/admin secret' });
    }

    const buf = Buffer.from(base64, 'base64');
    const fileBlob = new _Blob([buf], {
      type: mimeType || 'application/octet-stream',
    });

    const form = new _FormData();
    form.append('bucketId', bucketId);
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
    const metaBlob = new _Blob([JSON.stringify(meta)], {
      type: 'application/json',
    });
    form.append('metadata', metaBlob);
    form.append('file', fileBlob, safeBasename(filename));

    const upRes = await _fetch(`${storageUrl}/files`, {
      method: 'POST',
      headers: {
        'x-hasura-admin-secret': secret,
      },
      body: form,
    });

    const txt = await upRes.text();
    if (!upRes.ok) {
      let parsed = null;
      try {
        parsed = JSON.parse(txt);
      } catch (_) {}
      return res.status(upRes.status).json({
        error: 'storage-upload-failed',
        status: upRes.status,
        body: parsed ?? txt,
      });
    }

    return res.status(200).type('application/json').send(txt || '{}');
  } catch (e) {
    return res
      .status(500)
      .json({ error: 'internal', message: `${e?.message || e}` });
  }
};
