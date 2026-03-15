const {
  extractBearer,
  resolveUserIdFromToken,
} = require('../_shared/storage_utils');

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

async function runSql(sql, readOnly = true) {
  const url = resolveRunSqlUrl();
  const adminSecret =
    process.env.GRAPHQL_ADMIN_SECRET || process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!url || !adminSecret) {
    throw new Error('Missing HASURA admin secret for SQL');
  }
  const execute = async (includeSource) => {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-hasura-admin-secret': adminSecret,
      },
      body: JSON.stringify({
        type: 'run_sql',
        args: {
          ...(includeSource ? { source: 'default' } : {}),
          read_only: !!readOnly,
          sql,
        },
      }),
    });
    const text = await res.text();
    if (!res.ok) {
      if (
        includeSource &&
        text.includes('source with name "default" does not exist')
      ) {
        return execute(false);
      }
      throw new Error(`run_sql failed: ${res.status} ${text}`);
    }
    let json;
    try {
      json = text ? JSON.parse(text) : {};
    } catch (_) {
      throw new Error(`run_sql returned invalid JSON: ${text}`);
    }
    if (
      includeSource &&
      `${json?.error ?? ''}`.includes('source with name "default" does not exist')
    ) {
      return execute(false);
    }
    return json;
  };
  return execute(true);
}

const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

function normalizeSqlCell(value) {
  if (value === null || value === undefined || value === 'NULL') return null;
  if (value === 't') return true;
  if (value === 'f') return false;
  return value;
}

function firstResultObject(json) {
  const rows = Array.isArray(json?.result) ? json.result : null;
  if (!rows || rows.length < 2) return null;
  const headers = Array.isArray(rows[0]) ? rows[0] : null;
  const values = Array.isArray(rows[1]) ? rows[1] : null;
  if (!headers || !values) return null;
  const out = {};
  headers.forEach((header, index) => {
    out[header] = normalizeSqlCell(values[index]);
  });
  return out;
}

async function lookupAuthUserId(email) {
  const safeEmail = escapeLiteral(email);
  const sql = `select id from auth.users where lower(email)=lower('${safeEmail}') limit 1;`;
  const json = await runSql(sql);
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return row ? row[0] : null;
}

async function lookupAuthEmailById(userId) {
  const safeId = escapeLiteral(userId);
  const sql = `select email from auth.users where id='${safeId}' limit 1;`;
  const json = await runSql(sql, true);
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return row ? `${row[0] ?? ''}`.toLowerCase().trim() : '';
}

async function isSuperAdminUser(userId, email) {
  const safeId = escapeLiteral(userId);
  const safeEmail = escapeLiteral(email);
  const sql = `
    select 1
    from auth.user_roles
    where user_id='${safeId}' and role='superadmin'
    union all
    select 1
    from public.super_admins
    where user_uid='${safeId}' or lower(email)=lower('${safeEmail}')
    limit 1;
  `;
  const json = await runSql(sql, true);
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return !!row;
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
  if (userId) return userId;
  for (let i = 0; i < 6; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    userId = await lookupAuthUserId(email);
    if (userId) return userId;
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
  let userId = await signUpUser(email, password);
  if (userId) {
    return { id: userId, existed: false };
  }
  userId = await lookupAuthUserId(email);
  if (userId) {
    return { id: userId, existed: true };
  }
  for (let i = 0; i < 6; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    userId = await lookupAuthUserId(email);
    if (userId) {
      return { id: userId, existed: true };
    }
  }
  throw new Error('Auth user not found after signup');
}

async function deleteUser(userId) {
  const authUrl = resolveAuthUrl();
  const adminSecret =
    process.env.GRAPHQL_ADMIN_SECRET || process.env.NHOST_ADMIN_SECRET || process.env.HASURA_GRAPHQL_ADMIN_SECRET;
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
) {
  const sql = `
    select set_config('request.jwt.claim.role', 'service_role', true);
    select *
    from public.admin_create_owner_full(
      '${escapeLiteral(clinicName)}',
      '${escapeLiteral(ownerEmail)}',
      '${escapeLiteral(ownerPassword)}'
    );
  `;
  const row = firstResultObject(await runSql(sql, false));
  if (!row) {
    throw new Error('admin_create_owner_full returned no data');
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
    const token = extractBearer(req);
    const callerUid = token ? await resolveUserIdFromToken(token) : '';
    if (!callerUid) {
      res.status(401).json({ ok: false, error: 'Invalid token' });
      return;
    }
    const callerEmail = await lookupAuthEmailById(callerUid);
    if (!(await isSuperAdminUser(callerUid, callerEmail))) {
      res.status(403).json({ ok: false, error: 'forbidden' });
      return;
    }
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
