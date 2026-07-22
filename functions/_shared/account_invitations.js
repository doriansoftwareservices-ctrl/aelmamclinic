const crypto = require('crypto');
const {
  readBody,
  resolveUserIdFromToken,
  extractBearer,
  runSql,
} = require('./storage_utils');

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const tokenPattern = /^[A-Za-z0-9_-]{40,128}$/;
const escapeLiteral = (value) => `${value}`.replace(/'/g, "''");

const hashToken = (token) =>
  crypto.createHash('sha256').update(token, 'utf8').digest('hex');

const resultJson = (sqlResult) => {
  const row = Array.isArray(sqlResult?.result) ? sqlResult.result[1] : null;
  if (!row || !row[0]) return null;
  try {
    return JSON.parse(row[0]);
  } catch (_) {
    return null;
  }
};

async function authenticatedUser(req) {
  const uid = await resolveUserIdFromToken(extractBearer(req));
  return uuidPattern.test(`${uid || ''}`) ? uid : null;
}

async function createInvitation(req, { extraSeat = false } = {}) {
  const uid = await authenticatedUser(req);
  if (!uid) return { status: 401, payload: { ok: false, error: 'unauthorized' } };
  const body = await readBody(req);
  const accountId = `${body.account_id || body.accountId || ''}`.trim();
  const email = `${body.email || ''}`.trim().toLowerCase();
  if (!uuidPattern.test(accountId) || !emailPattern.test(email)) {
    return { status: 400, payload: { ok: false, error: 'invalid_invitation' } };
  }

  const token = crypto.randomBytes(32).toString('base64url');
  const tokenHash = hashToken(token);
  const expiresAt = new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString();
  const sql = `select public.create_account_invitation_secure(
    '${escapeLiteral(accountId)}'::uuid,
    '${escapeLiteral(email)}',
    '${tokenHash}',
    '${escapeLiteral(uid)}'::uuid,
    '${expiresAt}'::timestamptz,
    ${extraSeat ? 'true' : 'false'}
  )::text;`;
  const result = resultJson(await runSql(sql, false));
  if (!result) {
    return { status: 500, payload: { ok: false, error: 'invitation_failed' } };
  }
  if (result.ok !== true) {
    const status = result.error === 'forbidden' ? 403 : 409;
    return { status, payload: result };
  }
  return {
    status: 200,
    payload: {
      ...result,
      invitation_token: token,
      delivery: 'out_of_band',
    },
  };
}

async function transitionInvitation(action, token, uid) {
  if (!tokenPattern.test(token)) {
    return { ok: false, error: 'invalid_invitation_token' };
  }
  const functionName =
    action === 'accept'
      ? 'accept_account_invitation_secure'
      : 'reject_account_invitation_secure';
  const sql = `select public.${functionName}(
    '${hashToken(token)}',
    '${escapeLiteral(uid)}'::uuid
  )::text;`;
  return resultJson(await runSql(sql, false)) || {
    ok: false,
    error: 'invitation_failed',
  };
}

module.exports = {
  readBody,
  runSql,
  uuidPattern,
  tokenPattern,
  escapeLiteral,
  authenticatedUser,
  createInvitation,
  transitionInvitation,
  resultJson,
};
