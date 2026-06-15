const parseJsonBody = (value) => {
  if (value === null || value === undefined) return {};
  if (Buffer.isBuffer(value)) value = value.toString('utf8');
  if (typeof value === 'object') return value;
  if (typeof value !== 'string') return {};
  const trimmed = value.trim();
  if (!trimmed) return {};
  try {
    const decoded = JSON.parse(trimmed);
    return decoded && typeof decoded === 'object' ? decoded : {};
  } catch (_) {
    return {};
  }
};

const readBody = (req) =>
  new Promise((resolve) => {
    if (req.body !== undefined && req.body !== null) {
      resolve(parseJsonBody(req.body));
      return;
    }
    if (!req || typeof req.on !== 'function') {
      resolve({});
      return;
    }
    let data = '';
    req.on('data', (chunk) => (data += chunk));
    req.on('end', () => resolve(parseJsonBody(data)));
    req.on('error', () => resolve({}));
  });

const stripTrailing = (s) => (s || '').replace(/\/+$/, '');

const normalizeServiceUrl = (raw, service) => {
  if (!raw || !raw.includes('nhost.run')) return null;
  let base = stripTrailing(raw);
  base = base
    .replace(/\/v1\/graphql$/i, '')
    .replace(/\/v1$/i, '')
    .replace(/\/graphql$/i, '')
    .replace(/\/admin$/i, '');
  base = base
    .replace('.graphql.', `.${service}.`)
    .replace('.functions.', `.${service}.`)
    .replace('.auth.', `.${service}.`)
    .replace('.hasura.', `.${service}.`)
    .replace('.storage.', `.${service}.`);
  if (!base.includes(`.${service}.`)) return null;
  return `${base}/v1`;
};

const resolveServiceUrl = (service) => {
  const candidates = [
    process.env.NHOST_BACKEND_URL,
    process.env.NHOST_GRAPHQL_URL,
    process.env.NHOST_AUTH_URL,
    process.env.NHOST_FUNCTIONS_URL,
    process.env.NHOST_STORAGE_URL,
  ];
  for (const raw of candidates) {
    const u = normalizeServiceUrl(raw, service);
    if (u) return u;
  }
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.${service}.${region}.nhost.run/v1`;
  }
  return null;
};

const resolveAuthUrl = () => resolveServiceUrl('auth');
const resolveStorageUrl = () => resolveServiceUrl('storage');

const resolveHasuraV2Url = () => {
  const raw = process.env.NHOST_GRAPHQL_URL || process.env.NHOST_BACKEND_URL || '';
  if (!raw || !raw.includes('nhost.run')) return null;
  let base = stripTrailing(raw);
  base = base.replace('.graphql.', '.hasura.');
  base = base.replace(/\/v1\/graphql$/i, '').replace(/\/v1$/i, '');
  return `${base}/v2/query`;
};

const adminSecret = () =>
  process.env.GRAPHQL_ADMIN_SECRET ||
  process.env.NHOST_ADMIN_SECRET ||
  process.env.HASURA_GRAPHQL_ADMIN_SECRET;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isTransientSqlHttpStatus = (status) =>
  status === 0 || status === 502 || status === 503 || status === 504;

const isDefaultSourceMissing = (text) =>
  `${text ?? ''}`.includes('source with name "default" does not exist') ||
  `${text ?? ''}`.includes('source with name "default" was not found');

async function runSql(sql, readOnly = true) {
  const url = resolveHasuraV2Url();
  const secret = adminSecret();
  if (!url || !secret) throw new Error('Missing HASURA admin secret');

  const executeOnce = async (includeSource) => {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-hasura-admin-secret': secret,
      },
      body: JSON.stringify({
        type: 'run_sql',
        args: {
          ...(includeSource ? { source: 'default' } : {}),
          read_only: !!readOnly,
          sql,
        },
      }),
    });
    const text = await res.text();
    return { ok: res.ok, status: res.status, text };
  };

  const execute = async (includeSource) => {
    let lastText = '';
    let lastStatus = 0;

    for (let attempt = 1; attempt <= 4; attempt += 1) {
      const result = await executeOnce(includeSource);
      lastText = result.text;
      lastStatus = result.status;

      if (!result.ok) {
        if (includeSource && isDefaultSourceMissing(result.text)) {
          return execute(false);
        }
        if (isTransientSqlHttpStatus(result.status) && attempt < 4) {
          await sleep(250 * attempt * attempt);
          continue;
        }
        throw new Error(`run_sql failed: ${result.status} ${result.text}`);
      }

      let json;
      try {
        json = result.text ? JSON.parse(result.text) : {};
      } catch (_) {
        throw new Error(`run_sql returned invalid JSON: ${result.text}`);
      }
      if (includeSource && isDefaultSourceMissing(json?.error)) {
        return execute(false);
      }
      return json;
    }

    throw new Error(`run_sql failed after retries: ${lastStatus} ${lastText}`);
  };

  return execute(true);
}

const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

async function resolveUserIdFromToken(token) {
  if (!token) return null;
  const authUrl = resolveAuthUrl();
  if (!authUrl) return null;
  for (const url of [`${authUrl}/user`, `${authUrl}/v1/user`]) {
    try {
      const res = await fetch(url, { method: 'GET', headers: { Authorization: `Bearer ${token}` } });
      if (!res.ok) continue;
      const json = await res.json();
      return json?.id || json?.user?.id || json?.session?.user?.id || null;
    } catch (_) {}
  }
  return null;
}

function extractBearer(req) {
  const h = req.headers?.authorization || req.headers?.Authorization || '';
  const v = `${h}`.trim();
  const m = v.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

function safeBasename(path) {
  const parts = `${path || ''}`.split('/').filter(Boolean);
  return (parts[parts.length - 1] || '').trim() || `file_${Date.now()}`;
}

function parseChatIds({ filename, metadata }) {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const f = `${filename || ''}`;
  const m = f.match(/attachments\/([0-9a-fA-F-]{36})\/([0-9a-fA-F-]{36})\//);
  const conversationId =
    meta.conversation_id || meta.conversationId || (m ? m[1] : null);
  const messageId = meta.message_id || meta.messageId || (m ? m[2] : null);
  return {
    conversationId: conversationId ? `${conversationId}` : null,
    messageId: messageId ? `${messageId}` : null,
  };
}

async function isSuperAdmin(uid) {
  const u = escapeLiteral(uid);
  const json = await runSql(
    `select 1 from public.super_admins where user_uid='${u}' limit 1;`,
    true,
  );
  return !!(Array.isArray(json?.result) ? json.result[1] : null);
}

async function getParticipantRole(conversationId, uid) {
  const c = escapeLiteral(conversationId);
  const u = escapeLiteral(uid);
  const json = await runSql(
    `select role from public.chat_participants where conversation_id='${c}' and user_uid='${u}' limit 1;`,
    true,
  );
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return row ? row[0] || null : null;
}

async function messageBelongsToSender(messageId, uid, conversationId) {
  if (!messageId) return false;
  const m = escapeLiteral(messageId);
  const u = escapeLiteral(uid);
  const c = escapeLiteral(conversationId);
  const json = await runSql(
    `select 1 from public.chat_messages where id='${m}' and sender_uid='${u}' and conversation_id='${c}' limit 1;`,
    true,
  );
  return !!(Array.isArray(json?.result) ? json.result[1] : null);
}

async function ensureBucketExists(bucketId) {
  const b = escapeLiteral(bucketId);
  const json = await runSql(
    `select 1 from storage.buckets where id='${b}' limit 1;`,
    true,
  );
  return !!(Array.isArray(json?.result) ? json.result[1] : null);
}

module.exports = {
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
  runSql,
};
