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

async function ensureSuperAdmin(authHeader) {
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
      query:
        'query { fn_is_super_admin_gql { is_super_admin } }',
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
  if (!isSuper) {
    const err = new Error('forbidden');
    err.statusCode = 403;
    throw err;
  }
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
    await ensureSuperAdmin(authHeader);

    const body = await readBody(req);
    const fileId = `${body.fileId ?? ''}`.trim();
    const expiresIn = Number(body.expiresIn ?? 0) || 3600;
    if (!fileId) {
      res.status(400).json({ ok: false, error: 'Missing fileId' });
      return;
    }

    const storageUrl = resolveStorageUrl();
    const adminSecret =
      process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
    if (!storageUrl || !adminSecret) {
      res.status(500).json({ ok: false, error: 'Missing storage config' });
      return;
    }

    let meta = null;
    const metaRes = await fetch(`${storageUrl}/files/${fileId}/metadata`, {
      headers: {
        'x-hasura-admin-secret': adminSecret,
        Accept: 'application/json',
      },
    });
    if (metaRes.ok) {
      try {
        meta = await metaRes.json();
      } catch (_) {
        meta = null;
      }
    } else if (metaRes.status !== 404) {
      const txt = await metaRes.text();
      res
        .status(metaRes.status)
        .json({ ok: false, error: txt || 'Metadata lookup failed' });
      return;
    } else {
      const rawRes = await fetch(`${storageUrl}/files/${fileId}`, {
        headers: {
          'x-hasura-admin-secret': adminSecret,
          Accept: 'application/json',
        },
      });
      if (rawRes.ok) {
        try {
          meta = await rawRes.json();
        } catch (_) {
          meta = null;
        }
      }
    }
    if (meta?.bucketId && meta.bucketId !== 'subscription-proofs') {
      res.status(403).json({ ok: false, error: 'Bucket not allowed' });
      return;
    }

    const signAttempts = [
      {
        method: 'POST',
        url: `${storageUrl}/files/${fileId}/presigned`,
        body: JSON.stringify({ expiresIn }),
      },
      {
        method: 'GET',
        url: `${storageUrl}/files/${fileId}/presigned`,
      },
      {
        method: 'POST',
        url: `${storageUrl}/files/${fileId}/presigned-url`,
        body: JSON.stringify({ expiresIn }),
      },
      {
        method: 'GET',
        url: `${storageUrl}/files/${fileId}/presigned-url?expiresIn=${expiresIn}`,
      },
    ];

    let signRes;
    let payload;
    let lastText = '';
    for (const attempt of signAttempts) {
      signRes = await fetch(attempt.url, {
        method: attempt.method,
        headers: {
          'Content-Type': 'application/json',
          'x-hasura-admin-secret': adminSecret,
        },
        body: attempt.body,
      });
      lastText = await signRes.text();
      try {
        payload = JSON.parse(lastText);
      } catch (_) {
        payload = lastText;
      }
      if (signRes.ok) break;
    }

    if (!signRes || !signRes.ok) {
      res.status(signRes?.status || 500).json({
        ok: false,
        error: payload?.error ?? payload ?? 'Sign failed',
        hint: 'presigned lookup failed',
      });
      return;
    }

    res.status(signRes.status).json(payload);
  } catch (err) {
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
