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

const resolveAuthUrl = () => {
  const candidates = [
    process.env.NHOST_AUTH_URL,
    process.env.NHOST_AUTH_ADMIN_URL,
    process.env.NHOST_GRAPHQL_URL,
    process.env.NHOST_BACKEND_URL,
  ];
  for (const raw of candidates) {
    if (!raw) continue;
    if (!raw.includes('nhost.run')) continue;
    let url = raw.replace(/\/+$/, '');
    url = url
      .replace('.graphql.', '.auth.')
      .replace('.functions.', '.auth.')
      .replace('.storage.', '.auth.');
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
    return `https://${subdomain}.auth.${region}.nhost.run/v1`;
  }
  return null;
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

  const base = authUrl;
  const adminHeaders = {
    'Content-Type': 'application/json',
    'x-hasura-admin-secret': adminSecret,
    Authorization: `Bearer ${adminSecret}`,
  };

  const createRes = await fetch(`${base}/admin/users`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({
      email,
      password,
      emailVerified: true,
      active: true,
    }),
  });

  if (createRes.status === 409) {
    const listRes = await fetch(
      `${base}/admin/users?email=${encodeURIComponent(email)}`,
      { headers: adminHeaders },
    );
    if (!listRes.ok) {
      throw new Error(`Auth lookup failed: ${listRes.status}`);
    }
    const listJson = await listRes.json();
    const user = Array.isArray(listJson?.users) ? listJson.users[0] : null;
    if (!user || !user.id) {
      throw new Error('Auth user not found');
    }
    return user.id;
  }

  if (!createRes.ok) {
    const txt = await createRes.text();
    throw new Error(`Auth create failed: ${createRes.status} ${txt}`);
  }
  const json = await createRes.json();
  if (!json?.id) {
    throw new Error('Auth create returned no id');
  }
  return json.id;
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

    await createOrGetUser(ownerEmail, ownerPassword);
    const result = await callAdminCreateOwner(
      clinicName,
      ownerEmail,
      ownerPassword,
      authHeader,
    );
    res.json(result);
  } catch (err) {
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
