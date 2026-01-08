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
          my_profile { role account_id }
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
    const uploader = await ensureUploaderRole(authHeader);

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

    const meta = { name: filename };
    if (uploader && uploader.accountId) {
      meta.account_id = uploader.accountId;
    }

    const tryUpload = async (useArrayFields, includeMeta) => {
      const form = new FormData();
      form.append('bucket-id', bucketId);
      if (useArrayFields) {
        form.append('file[]', new Blob([buffer], { type: mimeType }), filename);
        if (includeMeta) {
          form.append(
            'metadata[]',
            JSON.stringify(meta),
          );
        }
      } else {
        form.append('file', new Blob([buffer], { type: mimeType }), filename);
        if (includeMeta) {
          form.append(
            'metadata',
            JSON.stringify(meta),
          );
        }
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
    res.status(500).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
