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

const ROOT_EMAIL = 'elmam.clinic.c.s@elmam.com';
const ALLOWED_TABS = [
  'clinics',
  'chats',
  'subscriptions',
  'payments',
  'complaints',
  'stats',
  'members',
];

const normalizeAuthUrl = (raw) => {
  if (!raw) return null;
  if (!raw.includes('nhost.run')) return null;
  let url = raw.replace(/\/+$/, '');
  const base = url.replace(/\/v1(\/admin)?$/i, '');
  const isServiceUrl =
    base.includes('.auth.') ||
    base.includes('.graphql.') ||
    base.includes('.functions.') ||
    base.includes('.storage.');
  if (!isServiceUrl && base.endsWith('.nhost.run')) {
    const region = process.env.NHOST_REGION;
    const subdomain = base.split('://')[1]?.split('.nhost.run')[0];
    if (subdomain && region) {
      return `https://${subdomain}.auth.${region}.nhost.run/v1`;
    }
    return null;
  }
  url = base
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

async function runSql(sql, readOnly = false) {
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
      args: { source: 'default', read_only: readOnly, sql },
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
  const json = await runSql(sql, true);
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

const parseJwtEmail = (authHeader) => {
  if (!authHeader) return '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  const parts = token.split('.');
  if (parts.length < 2) return '';
  try {
    const raw = Buffer.from(parts[1], 'base64').toString('utf8');
    const payload = JSON.parse(raw);
    const claims = payload['https://hasura.io/jwt/claims'] || {};
    return (
      (claims['x-hasura-user-email'] ||
        claims.email ||
        payload.email ||
        '') + ''
    )
      .toLowerCase()
      .trim();
  } catch (_) {
    return '';
  }
};

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

const sanitizeTabs = (tabs) => {
  const list = Array.isArray(tabs) ? tabs : [];
  const normalized = list
    .map((t) => `${t ?? ''}`.trim().toLowerCase())
    .filter((t) => ALLOWED_TABS.includes(t));
  return normalized.length > 0 ? Array.from(new Set(normalized)) : ALLOWED_TABS;
};

const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

module.exports = async function handler(req, res) {
  try {
    const body = await readBody(req);
    const authHeader = req.headers?.authorization;
    if (!authHeader) {
      res.status(401).json({ ok: false, error: 'Missing authorization' });
      return;
    }
    await ensureSuperAdmin(authHeader);
    const callerEmail = parseJwtEmail(authHeader);
    if (!callerEmail || callerEmail !== ROOT_EMAIL) {
      res.status(403).json({ ok: false, error: 'forbidden' });
      return;
    }

    const email = `${body.email ?? ''}`.trim().toLowerCase();
    const password = `${body.password ?? ''}`;
    if (!email || !password) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }

    const allowedTabs = sanitizeTabs(body.allowed_tabs);
    const userId = await ensureAuthUser(email, password);

    const safeEmail = escapeLiteral(email);
    const sql = `
      BEGIN;
      INSERT INTO auth.roles(role)
      VALUES ('superadmin')
      ON CONFLICT DO NOTHING;

      INSERT INTO auth.user_roles(user_id, role)
      VALUES ('${userId}', 'superadmin')
      ON CONFLICT DO NOTHING;

      INSERT INTO public.super_admins(email, user_uid)
      VALUES (lower('${safeEmail}'), '${userId}')
      ON CONFLICT (email) DO UPDATE SET user_uid = excluded.user_uid;

      INSERT INTO public.super_admin_tab_permissions(user_uid, allowed_tabs)
      VALUES ('${userId}', ARRAY[${allowedTabs
        .map((t) => `'${t}'`)
        .join(',')}]::text[])
      ON CONFLICT (user_uid) DO UPDATE
      SET allowed_tabs = excluded.allowed_tabs,
          updated_at = now();
      COMMIT;
    `;
    await runSql(sql, false);

    res.json({
      ok: true,
      user_uid: userId,
      email,
      allowed_tabs: allowedTabs,
    });
  } catch (err) {
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
