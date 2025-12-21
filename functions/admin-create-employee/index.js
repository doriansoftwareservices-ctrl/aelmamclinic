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

async function createOrGetUser(email, password) {
  const authUrl = process.env.NHOST_AUTH_URL;
  const adminSecret =
    process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!authUrl || !adminSecret) {
    throw new Error(
      'Missing NHOST_AUTH_URL or NHOST_ADMIN_SECRET/HASURA_GRAPHQL_ADMIN_SECRET',
    );
  }

  const createRes = await fetch(`${authUrl}/admin/users`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${adminSecret}`,
    },
    body: JSON.stringify({
      email,
      password,
      emailVerified: true,
      active: true,
    }),
  });

  if (createRes.status === 409) {
    const listRes = await fetch(
      `${authUrl}/admin/users?email=${encodeURIComponent(email)}`,
      {
        headers: {
          Authorization: `Bearer ${adminSecret}`,
        },
      },
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

async function callAdminCreateEmployee(accountId, email, password) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  const adminSecret =
    process.env.HASURA_GRAPHQL_ADMIN_SECRET || process.env.NHOST_ADMIN_SECRET;
  if (!gqlUrl || !adminSecret) {
    throw new Error(
      'Missing NHOST_GRAPHQL_URL or HASURA_GRAPHQL_ADMIN_SECRET/NHOST_ADMIN_SECRET',
    );
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
  const res = await fetch(gqlUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-hasura-admin-secret': adminSecret,
    },
    body: JSON.stringify({
      query,
      variables: { account: accountId, email, password },
    }),
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
}

async function ensureSuperAdmin(authHeader) {
  const gqlUrl = process.env.NHOST_GRAPHQL_URL;
  if (!gqlUrl) {
    throw new Error('Missing NHOST_GRAPHQL_URL');
  }
  const query = 'query { fn_is_super_admin_gql { user_uid email } }';
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
  if (!Array.isArray(rows) || rows.length === 0) {
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
    const accountId = `${body.account_id ?? ''}`.trim();
    const email = `${body.email ?? ''}`.trim().toLowerCase();
    const password = `${body.password ?? ''}`;

    if (!accountId || !email || !password) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }

    await createOrGetUser(email, password);
    const result = await callAdminCreateEmployee(accountId, email, password);
    res.json(result);
  } catch (err) {
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
