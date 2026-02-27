const { readBody, gqlRequest, sendFcm } = require('../_shared/notify_utils');

module.exports = async (req, res) => {
  try {
    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const planCode = row.plan_code || row.planCode || '';
    const clinicName = row.clinic_name || row.clinicName || '';
    const seatKind = row.seat_kind || row.seatKind || '';
    const seatStatus = row.status || '';
    const employeeEmail = row.employee_email || row.employeeEmail || '';

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

    let title = 'طلب ترقية جديد';
    let body = 'تم استلام طلب ترقية جديد';
    let type = 'plan_request';
    let payloadTag = 'plan_request';

    if (seatKind && String(seatKind).toLowerCase() === 'extra') {
      if (String(seatStatus).toLowerCase() !== 'submitted') {
        res.status(200).json({ ok: true, skipped: 'seat_not_submitted' });
        return;
      }
      title = 'طلب مقعد موظف إضافي';
      body = employeeEmail
        ? `تم إرسال طلب إضافة موظف: ${employeeEmail}`
        : 'تم إرسال طلب إضافة موظف إضافي';
      type = 'seat_request';
      payloadTag = 'seat_request';
    } else {
      const planLabel = planCode ? ` (${planCode})` : '';
      body =
        clinicName
          ? `تم استلام طلب ترقية من ${clinicName}${planLabel}`
          : `تم استلام طلب ترقية جديد${planLabel}`;
    }

    const data = { type, title, body, payload: payloadTag };

    const result = await sendFcm(tokens, {
      notification: { title, body },
      data,
    });
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    res.status(200).json({ ok: false, error: `${e}` });
  }
};
