const crypto = require('crypto');
const { createInvitation } = require('../_shared/account_invitations');

module.exports = async function handler(req, res) {
  const correlationId = crypto.randomUUID();
  try {
    if (req.method === 'OPTIONS') return res.status(204).end();
    if (req.method !== 'POST') {
      return res.status(405).json({
        ok: false,
        error: 'method_not_allowed',
        correlation_id: correlationId,
      });
    }
    const result = await createInvitation(req, { extraSeat: true });
    return res.status(result.status).json({
      ...result.payload,
      correlation_id: correlationId,
    });
  } catch (error) {
    console.error('extra employee invitation failed', {
      correlation_id: correlationId,
      error: `${error?.code || error?.name || 'internal'}`,
    });
    return res.status(500).json({
      ok: false,
      error: 'internal_error',
      correlation_id: correlationId,
    });
  }
};
