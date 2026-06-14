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

const ROOT_EMAIL = `${process.env.ROOT_SUPER_ADMIN_EMAIL || 'elmamclinic.admin@elmam.com'}`.toLowerCase().trim();
const ALLOWED_TABS = [
  'clinics',
  'chats',
  'support_ratings',
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isTransientSqlHttpStatus = (status) =>
  status === 0 || status === 502 || status === 503 || status === 504;

const isDefaultSourceMissing = (text) =>
  `${text ?? ''}`.includes('source with name "default" does not exist') ||
  `${text ?? ''}`.includes('source with name "default" was not found');

async function runSql(sql, readOnly = false) {
  const url = resolveRunSqlUrl();
  const adminSecret =
    process.env.GRAPHQL_ADMIN_SECRET ||
    process.env.NHOST_ADMIN_SECRET ||
    process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!url || !adminSecret) {
    throw new Error('Missing HASURA admin secret for SQL');
  }

  const executeOnce = async (includeSource) => {
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
    return { ok: res.ok, status: res.status, text };
  };

  const execute = async (includeSource) => {
    let lastStatus = 0;
    let lastText = '';
    for (let attempt = 1; attempt <= 4; attempt += 1) {
      const result = await executeOnce(includeSource);
      lastStatus = result.status;
      lastText = result.text;
      if (!result.ok) {
        if (includeSource && isDefaultSourceMissing(result.text)) {
          return execute(false);
        }
        if (isTransientSqlHttpStatus(result.status) && attempt < 4) {
          await sleep(250 * attempt * attempt);
          continue;
        }
        throw new Error(`run_sql failed: ${result.status} ${result.text}`);
      }
      let json;
      try {
        json = result.text ? JSON.parse(result.text) : {};
      } catch (_) {
        throw new Error(`run_sql returned invalid JSON: ${result.text}`);
      }
      if (includeSource && isDefaultSourceMissing(json?.error)) {
        return execute(false);
      }
      return json;
    }
    throw new Error(`run_sql failed after retries: ${lastStatus} ${lastText}`);
  };
  return execute(true);
}

async function lookupAuthUserId(email) {
  const safeEmail = escapeLiteral(email);
  const sql = `select id from auth.users where lower(email)=lower('${safeEmail}') limit 1;`;
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
  if (userId) return userId;
  for (let i = 0; i < 6; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    userId = await lookupAuthUserId(email);
    if (userId) return userId;
  }
  throw new Error('Auth user not found after signup');
}

async function createOrGetUser(email, password) {
  let userId = await signUpUser(email, password);
  if (userId) {
    return { id: userId, existed: false };
  }
  userId = await lookupAuthUserId(email);
  if (userId) {
    return { id: userId, existed: true };
  }
  userId = await ensureAuthUser(email, password);
  return { id: userId, existed: true };
}

const sanitizeTabs = (tabs) => {
  const list = Array.isArray(tabs) ? tabs : [];
  const normalized = list
    .map((t) => `${t ?? ''}`.trim().toLowerCase())
    .filter((t) => ALLOWED_TABS.includes(t));
  return normalized.length > 0 ? Array.from(new Set(normalized)) : ALLOWED_TABS;
};

const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

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

async function deleteUser(userId) {
  const authUrl = resolveAuthUrl();
  const adminSecret =
    process.env.GRAPHQL_ADMIN_SECRET ||
    process.env.NHOST_ADMIN_SECRET ||
    process.env.HASURA_GRAPHQL_ADMIN_SECRET;
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
    from auth.user_roles ur
    join auth.users u on u.id = ur.user_id
    where ur.user_id='${safeId}'
      and ur.role='superadmin'
      and coalesce(u.disabled, false) = false
    union all
    select 1
    from public.super_admins
    where (user_uid='${safeId}' or lower(email)=lower('${safeEmail}'))
      and coalesce(disabled, false) = false
    limit 1;
  `;
  const json = await runSql(sql, true);
  const row = Array.isArray(json?.result) ? json.result[1] : null;
  return !!row;
}

async function ensureWhitelistEmail(email) {
  const safeEmail = escapeLiteral(email);
  const sql = `
    insert into public.superadmin_whitelist(email)
    values (lower('${safeEmail}'))
    on conflict (email) do nothing;
  `;
  await runSql(sql, false);
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
    const password = `${body.password ?? ''}`;
    if (!email || !password) {
      res.status(400).json({ ok: false, error: 'Missing fields' });
      return;
    }
    if (password.length < 9) {
      res.status(400).json({ ok: false, error: 'Password too short' });
      return;
    }

    const allowedTabs = sanitizeTabs(body.allowed_tabs);
    created = await createOrGetUser(email, password);
    const userId = created.id;

    await ensureWhitelistEmail(email);

    const safeEmail = escapeLiteral(email);
    const safeUserId = escapeLiteral(userId);
    const allowedTabsSql = allowedTabs
      .map((t) => `'${escapeLiteral(t)}'`)
      .join(',');
    const sql = `
      BEGIN;

      CREATE TABLE IF NOT EXISTS public.super_admins (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        created_at timestamptz NOT NULL DEFAULT now(),
        account_id uuid,
        device_id text,
        local_id bigint,
        email text,
        user_uid uuid,
        disabled boolean NOT NULL DEFAULT false,
        default_role text NOT NULL DEFAULT 'superadmin',
        updated_at timestamptz NOT NULL DEFAULT now()
      );

      ALTER TABLE public.super_admins
        ADD COLUMN IF NOT EXISTS email text,
        ADD COLUMN IF NOT EXISTS user_uid uuid,
        ADD COLUMN IF NOT EXISTS disabled boolean NOT NULL DEFAULT false,
        ADD COLUMN IF NOT EXISTS default_role text NOT NULL DEFAULT 'superadmin',
        ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

      CREATE TABLE IF NOT EXISTS public.superadmin_whitelist (
        email text PRIMARY KEY,
        created_at timestamptz NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS public.super_admin_tab_permissions (
        user_uid uuid PRIMARY KEY,
        allowed_tabs text[] NOT NULL DEFAULT ARRAY['clinics','chats','support_ratings','subscriptions','payments','complaints','stats','members']::text[],
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      );

      INSERT INTO auth.roles(role)
      SELECT role
      FROM unnest(ARRAY['user','me','superadmin']::text[]) AS role
      ON CONFLICT DO NOTHING;

      UPDATE auth.users
      SET default_role = 'superadmin',
          email_verified = true,
          disabled = false,
          metadata = coalesce(metadata, '{}'::jsonb)
            || jsonb_build_object('role', 'superadmin', 'source', 'admin-create-superadmin'),
          updated_at = now()
      WHERE id='${safeUserId}';

      INSERT INTO auth.user_roles(user_id, role)
      SELECT '${safeUserId}'::uuid, role
      FROM unnest(ARRAY['user','me','superadmin']::text[]) AS role
      ON CONFLICT DO NOTHING;

      INSERT INTO public.super_admins(email, user_uid, disabled, default_role, updated_at)
      SELECT lower('${safeEmail}'), '${safeUserId}'::uuid, false, 'superadmin', now()
      WHERE NOT EXISTS (
        SELECT 1
        FROM public.super_admins sa
        WHERE lower(coalesce(sa.email, '')) = lower('${safeEmail}')
           OR sa.user_uid = '${safeUserId}'::uuid
      );

      UPDATE public.super_admins
      SET email = lower('${safeEmail}'),
          user_uid = '${safeUserId}'::uuid,
          disabled = false,
          default_role = 'superadmin',
          updated_at = now()
      WHERE lower(coalesce(email, '')) = lower('${safeEmail}')
         OR user_uid = '${safeUserId}'::uuid;

      INSERT INTO public.superadmin_whitelist(email)
      VALUES (lower('${safeEmail}'))
      ON CONFLICT (email) DO NOTHING;

      INSERT INTO public.super_admin_tab_permissions(user_uid, allowed_tabs, updated_at)
      VALUES ('${safeUserId}'::uuid, ARRAY[${allowedTabsSql}]::text[], now())
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
    if (created && created.id && created.existed === false) {
      await deleteUser(created.id);
    }
    const code = err?.statusCode ?? 500;
    res.status(code).json({ ok: false, error: err?.message ?? 'Failed' });
  }
};

