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

async function ensureUploaderRole(authHeader) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const res = await fetch(gqlUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader,
    },
    body: JSON.stringify({
      query: `
        query ProofUploaderRole {
          fn_is_super_admin_gql { is_super_admin }
          my_profile { role }
        }
      `,
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
  if (isSuper) return;
  const profile = json.data?.my_profile;
  const role = Array.isArray(profile) && profile.length > 0
    ? `${profile[0]?.role ?? ''}`.toLowerCase()
    : '';
  if (role === 'owner' || role === 'admin') {
    return;
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
    await ensureUploaderRole(authHeader);

    const body = await readBody(req);
    const filename = `${body.filename ?? ''}`.trim() || 'proof';
    const base64 = `${body.base64 ?? ''}`.trim();
    const bucketId = 'subscription-proofs';
    const mimeType =
      `${body.mimeType ?? 'application/octet-stream'}`.trim() ||
      'application/octet-stream';

    if (!base64) {
      res.status(400).json({ ok: false, error: 'Missing base64 payload' });
      return;
    }
    const maxBytes = 10 * 1024 * 1024;
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

    const form = new FormData();
    form.append('bucket-id', bucketId);
    form.append('file[]', new Blob([buffer], { type: mimeType }), filename);
    form.append(
      'metadata[]',
      new Blob([JSON.stringify({ name: filename })], { type: 'application/json' }),
      '',
    );

    const uploadRes = await fetch(`${storageUrl}/files`, {
      method: 'POST',
      headers: { 'x-hasura-admin-secret': adminSecret },
      body: form,
    });

    const text = await uploadRes.text();
    let payload = text;
    try { payload = JSON.parse(text); } catch (_) {}

    if (!uploadRes.ok) {
      res.status(uploadRes.status).json({
        ok: false,
        error: payload?.error ?? payload ?? 'Upload failed',
      });
      return;
    }

    res.status(uploadRes.status).json(payload);
  } catch (err) {
    res.status(500).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
