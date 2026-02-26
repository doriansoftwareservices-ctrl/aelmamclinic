const { readBody, gqlRequest, sendFcm } = require('../_shared/notify_utils');

module.exports = async (req, res) => {
  try {
    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const planCode = row.plan_code || row.planCode || '';
    const clinicName = row.clinic_name || row.clinicName || '';

    const admins = await gqlRequest(`query { super_admins { user_uid } }`, {});
    const uids = (admins?.super_admins || [])
      .map((s) => s.user_uid)
      .filter(Boolean);
    if (uids.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_admins' });
      return;
    }

    const tokensData = await gqlRequest(
      `query Tokens($uids: [uuid!]!) {
        push_device_tokens(
          where: {user_uid: {_in: $uids}, is_active: {_eq: true}}
        ) { token }
      }`,
      { uids },
    );
    const tokens = (tokensData?.push_device_tokens || [])
      .map((t) => t.token)
      .filter(Boolean);
    if (tokens.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const title = 'طلب ترقية جديد';
    const planLabel = planCode ? ` (${planCode})` : '';
    const body =
      clinicName
        ? `تم استلام طلب ترقية من ${clinicName}${planLabel}`
        : `تم استلام طلب ترقية جديد${planLabel}`;

    const data = {
      type: 'plan_request',
      title,
      body,
      payload: 'plan_request',
    };

    const result = await sendFcm(tokens, {
      notification: { title, body },
      data,
    });
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    res.status(200).json({ ok: false, error: `${e}` });
  }
};
