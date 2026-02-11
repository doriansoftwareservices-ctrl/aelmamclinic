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

const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

const parseJwtSub = (authHeader) => {
  if (!authHeader) return '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  const parts = token.split('.');
  if (parts.length < 2) return '';
  try {
    const padded = parts[1]
      .replace(/-/g, '+')
      .replace(/_/g, '/')
      .padEnd(parts[1].length + ((4 - (parts[1].length % 4)) % 4), '=');
    const raw = Buffer.from(padded, 'base64').toString('utf8');
    const payload = JSON.parse(raw);
    const claims = payload['https://hasura.io/jwt/claims'] || {};
    return (
      claims['x-hasura-user-id'] ||
      payload.sub ||
      claims.sub ||
      ''
    ).toString();
  } catch (_) {
    return '';
  }
};

const isUuid = (value) => /^[0-9a-f-]{36}$/i.test(`${value ?? ''}`);

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

async function lookupAuthUserId(email) {
  const safeEmail = escapeLiteral(email);
  const sql = `select id from auth.users where lower(email)=lower('${safeEmail}') limit 1;`;
  const json = await runSql(sql, true);
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return row ? row[0] : null;
}

module.exports = async function handler(req, res) {
  try {
    const body = await readBody(req);
    const authHeader = req.headers?.authorization;
    if (!authHeader) {
      res.status(401).json({ ok: false, error: 'Missing authorization' });
      return;
    }

    const callerUid = parseJwtSub(authHeader);
    if (!isUuid(callerUid)) {
      res.status(401).json({ ok: false, error: 'Invalid token' });
      return;
    }

    const callerEmail = await lookupAuthEmailById(callerUid);
    if (!callerEmail || callerEmail !== ROOT_EMAIL) {
      res.status(403).json({ ok: false, error: 'forbidden' });
      return;
    }

    const isSuper = await isSuperAdminUser(callerUid, callerEmail);
    if (!isSuper) {
      res.status(403).json({ ok: false, error: 'forbidden' });
      return;
    }

    const email = `${body.email ?? ''}`.trim().toLowerCase();
    const newPassword = `${body.new_password ?? ''}`.trim();
    if (!email || !newPassword) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }
    if (newPassword.length < 9) {
      res.status(400).json({ ok: false, error: 'Password too short' });
      return;
    }

    const targetId = await lookupAuthUserId(email);
    if (!targetId) {
      res.status(404).json({ ok: false, error: 'User not found' });
      return;
    }

    const safePass = escapeLiteral(newPassword);
    const safeId = escapeLiteral(targetId);
    const sql = `
      DO $$
      BEGIN
        BEGIN
          EXECUTE 'create extension if not exists pgcrypto';
        EXCEPTION WHEN insufficient_privilege THEN
          NULL;
        END;

        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema='auth' AND table_name='users' AND column_name='password_hash'
        ) THEN
          RAISE EXCEPTION 'password_hash_missing';
        END IF;

        UPDATE auth.users
        SET password_hash = crypt('${safePass}', gen_salt('bf')),
            updated_at = now()
        WHERE id='${safeId}';

        IF to_regclass('auth.refresh_tokens') IS NOT NULL THEN
          DELETE FROM auth.refresh_tokens WHERE user_id='${safeId}';
        END IF;
        IF to_regclass('auth.sessions') IS NOT NULL THEN
          DELETE FROM auth.sessions WHERE user_id='${safeId}';
        END IF;
      END $$;
    `;
    await runSql(sql, false);

    res.json({ ok: true, email, user_uid: targetId });
  } catch (err) {
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};
