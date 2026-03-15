const {
  readBody,
  extractBearer,
  resolveUserIdFromToken,
} = require('../_shared/storage_utils');

const stripTrailing = (value) => `${value || ''}`.replace(/\/+$/, '');

const normalizeGraphqlUrl = (raw) => {
  if (!raw || !raw.includes('nhost.run')) return null;
  let base = stripTrailing(raw);
  base = base
    .replace(/\/v1\/graphql$/i, '')
    .replace(/\/v1$/i, '')
    .replace(/\/graphql$/i, '')
    .replace(/\/admin$/i, '');
  base = base
    .replace('.functions.', '.graphql.')
    .replace('.auth.', '.graphql.')
    .replace('.storage.', '.graphql.')
    .replace('.hasura.', '.graphql.');
  if (!base.includes('.graphql.')) return null;
  return `${base}/v1/graphql`;
};

const resolveGraphqlUrl = () => {
  const candidates = [
    process.env.NHOST_GRAPHQL_URL,
    process.env.NHOST_BACKEND_URL,
    process.env.NHOST_FUNCTIONS_URL,
    process.env.NHOST_AUTH_URL,
  ];
  for (const raw of candidates) {
    const url = normalizeGraphqlUrl(raw);
    if (url) return url;
  }
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.graphql.${region}.nhost.run/v1/graphql`;
  }
  return null;
};

const adminSecret = () =>
  process.env.GRAPHQL_ADMIN_SECRET ||
  process.env.NHOST_ADMIN_SECRET ||
  process.env.HASURA_GRAPHQL_ADMIN_SECRET;

async function runGraphql(query, variables, { role, userId } = {}) {
  const url = resolveGraphqlUrl();
  const secret = adminSecret();
  if (!url || !secret) {
    throw new Error('Missing GraphQL admin configuration');
  }

  const headers = {
    'Content-Type': 'application/json',
    'x-hasura-admin-secret': secret,
  };
  if (role) headers['x-hasura-role'] = role;
  if (userId) headers['x-hasura-user-id'] = userId;

  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ query, variables }),
  });

  if (!response.ok) {
    throw new Error(`GraphQL failed: ${response.status} ${await response.text()}`);
  }

  const json = await response.json();
  if (Array.isArray(json?.errors) && json.errors.length > 0) {
    throw new Error(
      json.errors.map((e) => e?.message || 'GraphQL error').join(' | '),
    );
  }
  return json?.data || {};
}

function firstRow(data, field) {
  const value = data?.[field];
  if (Array.isArray(value)) return value[0] || null;
  if (value && typeof value === 'object') return value;
  return null;
}

async function lookupMembership(userId) {
  const query = `
    query LookupMembership($uid: uuid!) {
      account_users(
        where: { user_uid: { _eq: $uid } }
        order_by: { created_at: desc }
        limit: 1
      ) {
        account_id
        role
        disabled
      }
    }
  `;
  const data = await runGraphql(query, { uid: userId });
  return firstRow(data, 'account_users');
}

async function createAccountAsUser(userId, clinicName) {
  const mutation = `
    mutation SelfCreateAccount($clinic_name: String!) {
      self_create_account(
        args: { p_clinic_name: $clinic_name }
      ) {
        id
      }
    }
  `;
  const data = await runGraphql(
    mutation,
    { clinic_name: clinicName },
    { role: 'user', userId },
  );
  return firstRow(data, 'self_create_account');
}

function hasCompleteClinicProfile(profile) {
  return [
    profile.nameAr,
    profile.cityAr,
    profile.streetAr,
    profile.nearAr,
    profile.nameEn,
    profile.cityEn,
    profile.streetEn,
    profile.nearEn,
    profile.phone,
  ].every((value) => `${value || ''}`.trim().isNotEmpty);
}

async function updateClinicProfileAsUser(userId, profile) {
  if (!hasCompleteClinicProfile(profile)) return null;
  const mutation = `
    mutation UpdateClinicProfile(
      $name_ar: String!
      $city_ar: String!
      $street_ar: String!
      $near_ar: String!
      $name_en: String!
      $city_en: String!
      $street_en: String!
      $near_en: String!
      $phone: String!
      $phone2: String
    ) {
      update_clinic_profile(
        args: {
          p_clinic_name: $name_ar
          p_city_ar: $city_ar
          p_street_ar: $street_ar
          p_near_ar: $near_ar
          p_clinic_name_en: $name_en
          p_city_en: $city_en
          p_street_en: $street_en
          p_near_en: $near_en
          p_phone: $phone
          p_phone2: $phone2
        }
      ) {
        ok
        message
        account_id
        role
      }
    }
  `;

  const data = await runGraphql(
    mutation,
    {
      name_ar: profile.nameAr,
      city_ar: profile.cityAr,
      street_ar: profile.streetAr,
      near_ar: profile.nearAr,
      name_en: profile.nameEn,
      city_en: profile.cityEn,
      street_en: profile.streetEn,
      near_en: profile.nearEn,
      phone: profile.phone,
      phone2: profile.phone2 || null,
    },
    { role: 'user', userId },
  );
  return firstRow(data, 'update_clinic_profile');
}

module.exports = async function handler(req, res) {
  try {
    const authHeader = req.headers?.authorization || req.headers?.Authorization;
    if (!authHeader) {
      res.status(401).json({ ok: false, error: 'Missing authorization' });
      return;
    }

    const token = extractBearer(req);
    const userId = await resolveUserIdFromToken(token);
    if (!userId) {
      res.status(401).json({ ok: false, error: 'Invalid session' });
      return;
    }

    const body = await readBody(req);
    const profile = {
      nameAr: `${body.clinic_name ?? body.name_ar ?? ''}`.trim(),
      cityAr: `${body.city_ar ?? ''}`.trim(),
      streetAr: `${body.street_ar ?? ''}`.trim(),
      nearAr: `${body.near_ar ?? ''}`.trim(),
      nameEn: `${body.name_en ?? ''}`.trim(),
      cityEn: `${body.city_en ?? ''}`.trim(),
      streetEn: `${body.street_en ?? ''}`.trim(),
      nearEn: `${body.near_en ?? ''}`.trim(),
      phone: `${body.phone ?? ''}`.trim(),
      phone2: `${body.phone2 ?? body.phone_2 ?? ''}`.trim(),
    };

    if (!profile.nameAr) {
      res.status(400).json({ ok: false, error: 'clinic_name is required' });
      return;
    }

    let membership = await lookupMembership(userId);
    let created = false;

    if (membership?.account_id) {
      const role = `${membership.role ?? ''}`.trim().toLowerCase();
      if (role && role !== 'owner' && role !== 'admin') {
        res.status(409).json({
          ok: false,
          error: 'already linked to an account',
          account_id: membership.account_id,
          role,
        });
        return;
      }
    } else {
      const createdRow = await createAccountAsUser(userId, profile.nameAr);
      if (!createdRow?.id) {
        throw new Error('self_create_account returned no account id');
      }
      created = true;
      membership = {
        account_id: createdRow.id,
        role: 'owner',
        disabled: false,
      };
    }

    try {
      await updateClinicProfileAsUser(userId, profile);
    } catch (_) {}

    res.json({
      ok: true,
      created,
      account_id: membership?.account_id || null,
      role: `${membership?.role ?? 'owner'}`.trim().toLowerCase(),
    });
  } catch (err) {
    res.status(err?.statusCode || 500).json({
      ok: false,
      error: err?.message || 'Failed to create account',
    });
  }
};
