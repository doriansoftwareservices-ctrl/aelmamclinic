const readBody = (req) =>
  new Promise((resolve) => {
    if (req.body && typeof req.body === 'object') {
      resolve(req.body);
      return;
    }
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => {
      if (!data) { resolve({}); return; }
      try { resolve(JSON.parse(data)); } catch (_) { resolve({}); }
    });
  });

const resolveStorageUrl = () => {
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.storage.${region}.nhost.run/v1`;
  }

  const normalize = (raw) => {
    if (!raw) return null;
    let url = raw.replace(/\/+$/, '');
    if (!url.includes('nhost.run')) return null;

    url = url
      .replace('.graphql.', '.storage.')
      .replace('.hasura.', '.storage.')
      .replace('.functions.', '.storage.')
      .replace('.auth.', '.storage.')
      .replace('.backend.', '.storage.');

    url = url
      .replace(/\/v1\/graphql$/i, '')
      .replace(/\/graphql$/i, '')
      .replace(/\/v1$/i, '');

    if (!url.includes('.storage.') && region) {
      const m = url.match(/^https?:\/\/([a-z0-9-]+)(?:\.[a-z0-9-]+)*\.nhost\.run/i);
      if (m) {
        return `https://${m[1]}.storage.${region}.nhost.run/v1`;
      }
    }

    return `${url}/v1`;
  };

  const candidates = [
    process.env.NHOST_STORAGE_URL,
    process.env.NHOST_BACKEND_URL,
    process.env.NHOST_GRAPHQL_URL,
  ];
  for (const raw of candidates) {
    const normalized = normalize(raw);
    if (normalized) return normalized;
  }

  return null;
};

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
    const req = require('https').request(opts, (res) => {
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

async function ensureUploaderRole(authHeader) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const res = await postJson(
    gqlUrl,
    { Authorization: authHeader },
    {
      query: `
        query ProofUploaderRole {
          fn_is_super_admin_gql { is_super_admin }
          my_profile { role account_id }
        }
      `,
    },
  );
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`Auth check failed: ${res.status}`);
  }
  let json = {};
  try {
    json = JSON.parse(res.text || '{}');
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
  const profile = json.data?.my_profile;
  const row = Array.isArray(profile) && profile.length > 0 ? profile[0] : null;
  const role = `${row?.role ?? ''}`.toLowerCase();
  const accountId = `${row?.account_id ?? ''}`.trim();
  if ((role === 'owner' || role === 'admin') && accountId) {
    return { isSuper: false, accountId };
  }
  const err = new Error('forbidden');
  err.statusCode = 403;
  throw err;
}

module.exports = async function handler(req, res) {
  let stage = 'start';
  const reqId = `${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 8)}`;
  const DEBUG = ['1', 'true', 'yes'].includes(
    String(process.env.DEBUG_SUBSCRIPTION_PROOF || '').toLowerCase(),
  );
  const log = (...a) =>
    console.log('[admin-upload-subscription-proof]', reqId, stage, ...a);
  const fail = (status, msg, err) => {
    const payload = { ok: false, stage, reqId, message: msg, status };
    const errText = err ? String(err?.message ?? err) : '';
    payload.error = `stage=${stage} reqId=${reqId} ${msg}${
      errText ? ` | ${errText}` : ''
    }`.trim();
    if (DEBUG && err?.stack) payload.stack = err.stack;
    try {
      log('FAIL', status, payload);
    } catch (_) {}
    return res.status(status).json(payload);
  };
  log('START', {
    method: req.method,
    url: req.url,
    ct: req.headers && (req.headers['content-type'] || req.headers['Content-Type']),
  });

  try {
    stage = 'method';
  if (req.method !== 'POST') {
      return fail(405, 'method_not_allowed');
    }
    stage = 'auth_header';
  const authHeader = req.headers?.authorization;
    const adminSecret =
      process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
    const adminHeader =
      req.headers?.['x-hasura-admin-secret'] ||
      req.headers?.['x-nhost-admin-secret'];
    const hasAdminSecret =
      adminSecret && adminHeader && `${adminHeader}` === `${adminSecret}`;
    if (!authHeader && !hasAdminSecret) {
      return fail(401, 'missing_authorization');
    }
    stage = 'ensure_uploader_role';
  const uploader = hasAdminSecret
      ? { isSuper: true, accountId: '' }
      : await ensureUploaderRole(authHeader);

    stage = 'read_body';
  const body = await readBody(req);
    const payload =
      body && typeof body === 'object' && body.input && typeof body.input === 'object'
        ? body.input
        : body;
    const filename = `${payload?.filename ?? ''}`.trim() || 'proof';
    let base64 = `${payload?.base64 ?? ''}`.trim();
    if (base64.startsWith('data:')) {
      const comma = base64.indexOf(',');
      base64 = comma >= 0 ? base64.slice(comma + 1).trim() : '';
    }
    const bucketId = 'subscription-proofs';
    const mimeType =
      `${payload?.mimeType ?? 'application/octet-stream'}`.trim() ||
      'application/octet-stream';

    if (!base64) {
      return fail(400, 'missing_base64_payload');
    }
    const maxBytes = 10 * 1024 * 1024;
    stage = 'decode_base64';
  const buffer = Buffer.from(base64, 'base64');
    if (buffer.length > maxBytes) {
      return fail(413, 'file_too_large');
    }

    stage = 'resolve_storage_url';
  const storageUrl = resolveStorageUrl();
    // Reuse adminSecret from auth_header stage.
    if (!storageUrl || !adminSecret) {
      return fail(500, 'missing_storage_config');
    }

    const meta = { name: filename };
    if (uploader && uploader.accountId) {
      meta.metadata = { account_id: uploader.accountId };
    }

    const tryUpload = async (useArrayFields, includeMeta) => {
      const fields = { 'bucket-id': bucketId };
      const extraFiles = [];
      if (includeMeta) {
        const metaJson = JSON.stringify(meta);
        fields[useArrayFields ? 'metadata[]' : 'metadata'] = metaJson;
        extraFiles.push({
          name: useArrayFields ? 'metadata[]' : 'metadata',
          filename: '',
          contentType: 'application/json',
          buffer: Buffer.from(metaJson, 'utf8'),
        });
      }
      // Add both file and file[] to satisfy storage validators in different versions.
      const primaryField = useArrayFields ? 'file[]' : 'file';
      const secondaryField = useArrayFields ? 'file' : 'file[]';
      extraFiles.push({
        name: secondaryField,
        filename,
        contentType: mimeType,
        buffer,
      });
      const multipart = buildMultipart({
        fieldName: primaryField,
        filename,
        contentType: mimeType,
        buffer,
        fields,
        extraFiles,
      });

      const res = await postMultipart(
        `${storageUrl}/files`,
        {
          'x-hasura-admin-secret': adminSecret,
          'x-nhost-admin-secret': adminSecret,
          ...multipart.headers,
        },
        multipart.body,
      );

      let responsePayload = res.text;
      try {
        responsePayload = JSON.parse(res.text);
      } catch (_) {}
      return { uploadRes: { ok: res.status >= 200 && res.status < 300, status: res.status }, responsePayload };
    };

    stage = 'upload_attempts';
    const attempts = [
      { arrayFields: true, includeMeta: true },
      { arrayFields: true, includeMeta: false },
      { arrayFields: false, includeMeta: true },
      { arrayFields: false, includeMeta: false },
    ];
    let uploadRes;
    let responsePayload;
    let responseText;
    for (const attempt of attempts) {
      ({ uploadRes, responsePayload } = await tryUpload(
        attempt.arrayFields,
        attempt.includeMeta,
      ));
      responseText =
        typeof responsePayload === 'string'
          ? responsePayload
          : JSON.stringify(responsePayload ?? {});
      if (uploadRes.ok) break;
    }

    stage = 'upload_failed';
  if (!uploadRes || !uploadRes.ok) {
      const detail = `upload_failed status=${uploadRes?.status || 0} body=${responseText ?? ''}`;
      return fail(
        uploadRes?.status || 500,
        detail,
        detail,
      );
    }

    res.status(uploadRes.status).json(responsePayload);
  } catch (err) {
    try {
      console.error('[admin-upload-subscription-proof] Error:', err);
    } catch (_) {}
    return fail(500, 'internal_error', err);
  }
};
