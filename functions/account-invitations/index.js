const crypto = require('crypto');
const {
  readBody,
  runSql,
  uuidPattern,
  escapeLiteral,
  authenticatedUser,
  transitionInvitation,
  resultJson,
} = require('../_shared/account_invitations');

const fail = (res, status, error, correlationId) =>
  res.status(status).json({
    ok: false,
    error,
    correlation_id: correlationId,
  });

module.exports = async function handler(req, res) {
  const correlationId = crypto.randomUUID();
  try {
    if (req.method !== 'POST') {
      return fail(res, 405, 'method_not_allowed', correlationId);
    }
    const uid = await authenticatedUser(req);
    if (!uid) return fail(res, 401, 'unauthorized', correlationId);
    const body = await readBody(req);
    const action = `${body.action || 'list'}`.trim().toLowerCase();

    if (action === 'accept' || action === 'reject') {
      const token = `${body.token || body.invitation_token || ''}`.trim();
      const result = await transitionInvitation(action, token, uid);
      const status = result.ok === true ? 200 : 409;
      return res.status(status).json({
        ...result,
        correlation_id: correlationId,
      });
    }

    if (action === 'revoke') {
      const invitationId = `${body.invitation_id || body.invitationId || ''}`.trim();
      if (!uuidPattern.test(invitationId)) {
        return fail(res, 400, 'invalid_invitation_id', correlationId);
      }
      const sql = `select public.revoke_account_invitation_secure(
        '${escapeLiteral(invitationId)}'::uuid,
        '${escapeLiteral(uid)}'::uuid
      )::text;`;
      const result = resultJson(await runSql(sql, false));
      if (!result) return fail(res, 500, 'invitation_failed', correlationId);
      return res.status(result.ok === true ? 200 : 409).json({
        ...result,
        correlation_id: correlationId,
      });
    }

    if (action !== 'list' && action !== 'list_owned') {
      return fail(res, 400, 'invalid_action', correlationId);
    }
    await runSql(
      `update public.account_invitations
          set status='expired'
        where status='pending' and expires_at <= now();`,
      false,
    );
    const predicate = action === 'list_owned'
      ? `exists (
           select 1 from public.account_users owner_membership
            where owner_membership.account_id=i.account_id
              and owner_membership.user_uid='${escapeLiteral(uid)}'::uuid
              and lower(coalesce(owner_membership.role,''))='owner'
              and coalesce(owner_membership.disabled,false)=false
         )`
      : `i.email=(select lower(email) from auth.users where id='${escapeLiteral(uid)}'::uuid)`;
    const json = await runSql(
      `select i.id::text, i.account_id::text, a.name, i.email, i.role,
              i.status, i.expires_at::text, i.created_at::text,
              i.seat_request_id::text
         from public.account_invitations i
         join public.accounts a on a.id=i.account_id
        where ${predicate}
        order by i.created_at desc
        limit 200;`,
      true,
    );
    const rows = Array.isArray(json?.result) ? json.result.slice(1) : [];
    return res.status(200).json({
      ok: true,
      invitations: rows.map((row) => ({
        id: row[0],
        account_id: row[1],
        account_name: row[2],
        email: row[3],
        role: row[4],
        status: row[5],
        expires_at: row[6],
        created_at: row[7],
        seat_request_id: row[8] || null,
      })),
      correlation_id: correlationId,
    });
  } catch (error) {
    console.error('account invitation operation failed', {
      correlation_id: correlationId,
      error: `${error?.code || error?.name || 'internal'}`,
    });
    return fail(res, 500, 'internal_error', correlationId);
  }
};
