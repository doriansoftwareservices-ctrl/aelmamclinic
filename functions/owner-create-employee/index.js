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

const normalizeAuthUrl = (raw) => {
  if (!raw) return null;
  if (!raw.includes('nhost.run')) return null;
  let url = raw.replace(/\/+$/, '');
  const isServiceUrl =
    url.includes('.auth.') ||
    url.includes('.graphql.') ||
    url.includes('.functions.') ||
    url.includes('.storage.');
  if (!isServiceUrl && url.endsWith('.nhost.run')) {
    const region = process.env.NHOST_REGION;
    const subdomain = url.split('://')[1]?.split('.nhost.run')[0];
    if (subdomain && region) {
      return `https://${subdomain}.auth.${region}.nhost.run/v1`;
    }
    return null;
  }
  url = url
    .replace('.graphql.', '.auth.')
    .replace('.functions.', '.auth.')
    .replace('.storage.', '.auth.');
  url = url.replace(/\/admin\/?$/i, '').replace(/\/v1\/admin\/?$/i, '/v1');
  url = url
    .replace(/\/v1\/graphql$/i, '')
    .replace(/\/graphql$/i, '')
    .replace(/\/v1$/i, '');
  return `${url}/v1`;
};

const resolveAuthUrl = () => {
  const candidates = [
    process.env.NHOST_AUTH_URL,
    process.env.NHOST_AUTH_ADMIN_URL,
    process.env.NHOST_GRAPHQL_URL,
    process.env.NHOST_BACKEND_URL,
  ];
  for (const raw of candidates) {
    const url = normalizeAuthUrl(raw);
    if (url) return url;
  }
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.auth.${region}.nhost.run/v1`;
  }
  return null;
};

const adminUserEndpoints = (authUrl) => {
  if (!authUrl) return [];
  const raw = authUrl.replace(/\/+$/, '');
  const root = raw.replace(/\/v1$/i, '');
  const endpoints = [
    `${raw}/admin/users`,
    `${root}/admin/users`,
    `${root}/v1/admin/users`,
  ];
  return [...new Set(endpoints)];
};

async function createOrGetUser(email, password) {
  const authUrl = resolveAuthUrl();
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!authUrl || !adminSecret) {
    throw new Error(
      'Missing NHOST_AUTH_URL or NHOST_ADMIN_SECRET/HASURA_GRAPHQL_ADMIN_SECRET',
    );
  }

  const adminHeaders = {
    'Content-Type': 'application/json',
    'x-hasura-admin-secret': adminSecret,
    Authorization: `Bearer ${adminSecret}`,
  };

  let lastErr = null;
  for (const endpoint of adminUserEndpoints(authUrl)) {
    const createRes = await fetch(endpoint, {
      method: 'POST',
      headers: adminHeaders,
      body: JSON.stringify({
        email,
        password,
        emailVerified: true,
        active: true,
      }),
    });

    if (createRes.status === 404) {
      lastErr = new Error(`Auth create failed: ${createRes.status} 404`);
      continue;
    }

    if (createRes.status === 409) {
      const listRes = await fetch(
        `${endpoint}?email=${encodeURIComponent(email)}`,
        {
          headers: adminHeaders,
        },
      );
      if (listRes.status === 404) {
        lastErr = new Error(`Auth lookup failed: ${listRes.status} 404`);
        continue;
      }
      if (!listRes.ok) {
        const txt = await listRes.text();
        throw new Error(`Auth lookup failed: ${listRes.status} ${txt}`);
      }
      const listJson = await listRes.json();
      const user = Array.isArray(listJson?.users) ? listJson.users[0] : null;
      if (!user || !user.id) {
        throw new Error('Auth user not found');
      }
      return { id: user.id, existed: true };
    }

    if (!createRes.ok) {
      const txt = await createRes.text();
      throw new Error(`Auth create failed: ${createRes.status} ${txt}`);
    }
    const json = await createRes.json();
    if (!json?.id) {
      throw new Error('Auth create returned no id');
    }
    return { id: json.id, existed: false };
  }
  if (lastErr) {
    throw lastErr;
  }
  throw new Error('Auth create failed');
}

async function deleteUser(userId) {
  const authUrl = resolveAuthUrl();
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!authUrl || !adminSecret || !userId) return;
  const headers = {
    'x-hasura-admin-secret': adminSecret,
    Authorization: `Bearer ${adminSecret}`,
  };
  for (const endpoint of adminUserEndpoints(authUrl)) {
    const res = await fetch(`${endpoint}/${userId}`, {
      method: 'DELETE',
      headers,
    });
    if (res.status !== 404) break;
  }
}

async function ensureOwner(authHeader) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) throw new Error('Missing NHOST_GRAPHQL_URL');
  const query = `
    query MeRole {
      my_profile {
        role
      }
    }
  `;
  const res = await fetch(gqlUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader,
    },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) {
    throw new Error(`Auth check failed: ${res.status}`);
  }
  const json = await res.json();
  if (json.errors?.length) {
    throw new Error(json.errors.map((e) => e.message).join(' | '));
  }
  const rows = json.data?.my_profile;
  const role = Array.isArray(rows) && rows.length > 0 ? rows[0]?.role : null;
  if (!role || role.toLowerCase() !== 'owner') {
    const err = new Error('forbidden');
    err.statusCode = 403;
    throw err;
  }
}

async function callOwnerCreateEmployee(authHeader, email, password) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) throw new Error('Missing NHOST_GRAPHQL_URL');
  const query = `
    mutation OwnerCreateEmployee($email: String!, $password: String!) {
      owner_create_employee_within_limit(
        args: {p_email: $email, p_password: $password}
      ) {
        ok
        error
        account_id
        user_uid
        role
        disabled
      }
    }
  `;
  const res = await fetch(gqlUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader,
    },
    body: JSON.stringify({ query, variables: { email, password } }),
  });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`GraphQL failed: ${res.status} ${txt}`);
  }
  const json = await res.json();
  if (json.errors?.length) {
    throw new Error(json.errors.map((e) => e.message).join(' | '));
  }
  const rows = json.data?.owner_create_employee_within_limit;
  const row = Array.isArray(rows) && rows.length > 0 ? rows[0] : rows;
  if (!row || row.ok !== true) {
    const msg = row?.error || 'Failed';
    const err = new Error(msg);
    err.statusCode = 400;
    throw err;
  }
  return row;
}

module.exports = async function handler(req, res) {
  let created = null;
  try {
    const body = await readBody(req);
    const authHeader = req.headers?.authorization;
    if (!authHeader) {
      res.status(401).json({ ok: false, error: 'Missing authorization' });
      return;
    }
    await ensureOwner(authHeader);

    const email = `${body.email ?? ''}`.trim().toLowerCase();
    const password = `${body.password ?? ''}`;
    if (!email || !password) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }

    created = await createOrGetUser(email, password);
    const result = await callOwnerCreateEmployee(authHeader, email, password);
    res.json(result);
  } catch (err) {
    if (created && created.id && created.existed === false) {
      await deleteUser(created.id);
    }
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
