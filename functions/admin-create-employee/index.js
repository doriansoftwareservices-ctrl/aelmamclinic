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
        { headers: adminHeaders },
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

async function callAdminCreateEmployee(
  accountId,
  email,
  password,
  authHeader,
) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  if (!authHeader) {
    throw new Error('Missing authorization');
  }
  const query = `
    mutation CreateEmployee($account: uuid!, $email: String!, $password: String!) {
      admin_create_employee_full(
        args: {p_account: $account, p_email: $email, p_password: $password}
      ) {
        ok
        error
        account_id
        user_uid
        role
      }
    }
  `;
  const payload = {
    query,
    variables: { account: accountId, email, password },
  };
  const run = async (headers) => {
    const res = await fetch(gqlUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`GraphQL failed: ${res.status} ${txt}`);
    }
    const json = await res.json();
    if (json.errors?.length) {
      throw new Error(json.errors.map((e) => e.message).join(' | '));
    }
    const rows = json.data?.admin_create_employee_full;
    if (Array.isArray(rows) && rows.length > 0) {
      return rows[0];
    }
    if (rows && typeof rows === 'object') {
      return rows;
    }
    return { ok: false, error: 'No data' };
  };
  try {
    return await run({
      'Content-Type': 'application/json',
      Authorization: authHeader,
      'x-hasura-role': 'superadmin',
    });
  } catch (err) {
    if (!adminSecret) {
      throw err;
    }
    return run({
      'Content-Type': 'application/json',
      'x-hasura-admin-secret': adminSecret,
      'x-hasura-role': 'service_role',
    });
  }
}

async function ensureSuperAdmin(authHeader) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const query = 'query { fn_is_super_admin_gql { is_super_admin } }';
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
  const rows = json.data?.fn_is_super_admin_gql;
  const isSuper =
    Array.isArray(rows) && rows.length > 0 && rows[0]?.is_super_admin === true;
  if (!isSuper) {
    const err = new Error('forbidden');
    err.statusCode = 403;
    throw err;
  }
}

async function ensureAccountPaid(accountId, authHeader) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const query = `
    query AccountPaid($account: uuid!) {
      account_is_paid_gql(args: {p_account: $account}) {
        account_is_paid
      }
    }
  `;
  const payload = { query, variables: { account: accountId } };
  const run = async (headers) => {
    const res = await fetch(gqlUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      throw new Error(`Plan check failed: ${res.status}`);
    }
    const json = await res.json();
    if (json.errors?.length) {
      throw new Error(json.errors.map((e) => e.message).join(' | '));
    }
    const raw = json.data?.account_is_paid_gql;
    if (Array.isArray(raw) && raw.length > 0) {
      return raw[0]?.account_is_paid === true;
    }
    return false;
  };

  try {
    return await run({
      'Content-Type': 'application/json',
      Authorization: authHeader,
      'x-hasura-role': 'superadmin',
    });
  } catch (err) {
    if (!adminSecret) {
      throw err;
    }
    return run({
      'Content-Type': 'application/json',
      'x-hasura-admin-secret': adminSecret,
      'x-hasura-role': 'service_role',
    });
  }
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
    await ensureSuperAdmin(authHeader);
    const accountId = `${body.account_id ?? ''}`.trim();
    const email = `${body.email ?? ''}`.trim().toLowerCase();
    const password = `${body.password ?? ''}`;

    if (!accountId || !email || !password) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }

    const paid = await ensureAccountPaid(accountId, authHeader);
    if (!paid) {
      res.status(403).json({ ok: false, error: 'plan is free' });
      return;
    }

    created = await createOrGetUser(email, password);
    const result = await callAdminCreateEmployee(
      accountId,
      email,
      password,
      authHeader,
    );
    res.json(result);
  } catch (err) {
    if (created && created.id && created.existed === false) {
      await deleteUser(created.id);
    }
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
