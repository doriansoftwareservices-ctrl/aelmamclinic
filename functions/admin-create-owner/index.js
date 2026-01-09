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

const resolveRunSqlUrl = () => {
  const raw =
    process.env.NHOST_GRAPHQL_URL || process.env.NHOST_BACKEND_URL || '';
  if (!raw || !raw.includes('nhost.run')) return null;
  let base = raw.replace(/\/+$/, '');
  base = base.replace('.graphql.', '.hasura.');
  base = base.replace(/\/v1\/graphql$/i, '').replace(/\/v1$/i, '');
  return `${base}/v2/query`;
};

async function runSql(sql) {
  const url = resolveRunSqlUrl();
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!url || !adminSecret) {
    throw new Error('Missing HASURA admin secret for SQL');
  }
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-hasura-admin-secret': adminSecret,
    },
    body: JSON.stringify({
      type: 'run_sql',
      args: { source: 'default', read_only: true, sql },
    }),
  });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`run_sql failed: ${res.status} ${txt}`);
  }
  return res.json();
}

async function lookupAuthUserId(email) {
  const sql = `select id from auth.users where lower(email)=lower('${email}') limit 1;`;
  const json = await runSql(sql);
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return row ? row[0] : null;
}

async function signUpUser(email, password) {
  const authUrl = resolveAuthUrl();
  if (!authUrl) throw new Error('Missing NHOST_AUTH_URL');
  const res = await fetch(`${authUrl}/signup/email-password`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (res.status === 409) return null;
  if (!res.ok) {
    const txt = await res.text();
    if (txt.includes('already') || txt.includes('exists')) return null;
    throw new Error(`Auth signup failed: ${res.status} ${txt}`);
  }
  const json = await res.json();
  return json?.user?.id || json?.session?.user?.id || null;
}

async function ensureAuthUser(email, password) {
  let userId = await signUpUser(email, password);
  if (!userId) {
    userId = await lookupAuthUserId(email);
  }
  if (!userId) {
    throw new Error('Auth user not found after signup');
  }
  return userId;
}

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
  const userId = await ensureAuthUser(email, password);
  return { id: userId, existed: true };
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

async function callAdminCreateOwner(
  clinicName,
  ownerEmail,
  ownerPassword,
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
    mutation CreateOwner($clinic: String!, $email: String!, $password: String!) {
      admin_create_owner_full(
        args: {p_clinic_name: $clinic, p_owner_email: $email, p_owner_password: $password}
      ) {
        ok
        error
        account_id
        owner_uid
        user_uid
        role
      }
    }
  `;
  const payload = {
    query,
    variables: { clinic: clinicName, email: ownerEmail, password: ownerPassword },
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
    const rows = json.data?.admin_create_owner_full;
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
    const clinicName = `${body.clinic_name ?? ''}`.trim();
    const ownerEmail = `${body.owner_email ?? ''}`.trim().toLowerCase();
    const ownerPassword = `${body.owner_password ?? ''}`;

    if (!clinicName || !ownerEmail || !ownerPassword) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }

    created = await createOrGetUser(ownerEmail, ownerPassword);
    const result = await callAdminCreateOwner(
      clinicName,
      ownerEmail,
      ownerPassword,
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
