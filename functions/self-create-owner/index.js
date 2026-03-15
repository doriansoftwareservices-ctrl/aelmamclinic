const {
  readBody,
  extractBearer,
  resolveUserIdFromToken,
  runSql,
} = require('../_shared/storage_utils');
const escapeLiteral = (value) => `${value ?? ''}`.replace(/'/g, "''");

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

async function lookupMembership(userId) {
  const safeUserId = escapeLiteral(userId);
  const sql = `
    select account_id, role, disabled
    from public.account_users
    where user_uid='${safeUserId}'
    order by created_at desc
    limit 1;
  `;
  return firstResultObject(await runSql(sql, true));
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
  ].every((value) => `${value || ''}`.trim() !== '');
}

async function createAccountAsUser(userId, profile) {
  if (!hasCompleteClinicProfile(profile)) {
    throw new Error('Complete clinic profile is required');
  }
  const safeUserId = escapeLiteral(userId);
  const sql = `
    select set_config('request.jwt.claim.role', 'user', true);
    select set_config('x-hasura-user-id', '${safeUserId}', true);
    select *
    from public.self_create_account(
      '${escapeLiteral(profile.nameAr)}',
      '${escapeLiteral(profile.cityAr)}',
      '${escapeLiteral(profile.streetAr)}',
      '${escapeLiteral(profile.nearAr)}',
      '${escapeLiteral(profile.nameEn)}',
      '${escapeLiteral(profile.cityEn)}',
      '${escapeLiteral(profile.streetEn)}',
      '${escapeLiteral(profile.nearEn)}',
      '${escapeLiteral(profile.phone)}',
      ${profile.phone2 ? `'${escapeLiteral(profile.phone2)}'` : 'NULL'}
    );
  `;
  return firstResultObject(await runSql(sql, false));
}

async function updateClinicProfileAsUser(userId, profile) {
  if (!hasCompleteClinicProfile(profile)) return null;
  const safeUserId = escapeLiteral(userId);
  const sql = `
    select set_config('request.jwt.claim.role', 'user', true);
    select set_config('x-hasura-user-id', '${safeUserId}', true);
    select *
    from public.update_clinic_profile(
      '${escapeLiteral(profile.nameAr)}',
      '${escapeLiteral(profile.cityAr)}',
      '${escapeLiteral(profile.streetAr)}',
      '${escapeLiteral(profile.nearAr)}',
      '${escapeLiteral(profile.nameEn)}',
      '${escapeLiteral(profile.cityEn)}',
      '${escapeLiteral(profile.streetEn)}',
      '${escapeLiteral(profile.nearEn)}',
      '${escapeLiteral(profile.phone)}',
      ${profile.phone2 ? `'${escapeLiteral(profile.phone2)}'` : 'NULL'}
    );
  `;
  return firstResultObject(await runSql(sql, false));
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
      if (!hasCompleteClinicProfile(profile)) {
        res.status(400).json({
          ok: false,
          error: 'complete clinic profile is required',
        });
        return;
      }
      const createdRow = await createAccountAsUser(userId, profile);
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
