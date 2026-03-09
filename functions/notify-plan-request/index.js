const {
  readBody,
  gqlRequest,
  sendFcm,
  groupTokensByLocale,
  mergeSendResults,
  normalizeLanguageCode,
} = require('../_shared/notify_utils');

const buildPlanPayload = ({
  languageCode,
  clinicName,
  planCode,
  employeeEmail,
  isSeatRequest,
}) => {
  const locale = normalizeLanguageCode(languageCode);
  const planLabel = planCode ? ` (${planCode})` : '';
  let title = locale === 'en' ? 'New upgrade request' : 'طلب ترقية جديد';
  let body = locale === 'en'
    ? `A new upgrade request was received${planLabel}`
    : `تم استلام طلب ترقية جديد${planLabel}`;
  let type = 'plan_request';
  let payload = 'admin:plan_request';

  if (isSeatRequest) {
    title = locale === 'en'
      ? 'Additional employee seat request'
      : 'طلب مقعد موظف إضافي';
    body = employeeEmail
      ? (locale === 'en'
          ? `Additional employee request submitted: ${employeeEmail}`
          : `تم إرسال طلب إضافة موظف: ${employeeEmail}`)
      : (locale === 'en'
          ? 'An additional employee request was submitted'
          : 'تم إرسال طلب إضافة موظف إضافي');
    type = 'seat_request';
    payload = 'admin:seat_request';
  } else if (clinicName) {
    body = locale === 'en'
      ? `An upgrade request was received from ${clinicName}${planLabel}`
      : `تم استلام طلب ترقية من ${clinicName}${planLabel}`;
  }

  return {
    notification: { title, body },
    data: {
      type,
      title,
      body,
      payload,
    },
  };
};

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
      .map((entry) => entry.user_uid)
      .filter(Boolean);
    if (uids.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_admins' });
      return;
    }

    let tokenRows = [];
    try {
      const tokensData = await gqlRequest(
        `query Tokens($uids: [uuid!]!) {
          push_device_tokens(
            where: {user_uid: {_in: $uids}, is_active: {_eq: true}}
          ) { token locale_code }
        }`,
        { uids },
      );
      tokenRows = tokensData?.push_device_tokens || [];
    } catch (error) {
      if (!`${error}`.includes('locale_code')) throw error;
      const legacyTokens = await gqlRequest(
        `query TokensLegacy($uids: [uuid!]!) {
          push_device_tokens(
            where: {user_uid: {_in: $uids}, is_active: {_eq: true}}
          ) { token }
        }`,
        { uids },
      );
      tokenRows = (legacyTokens?.push_device_tokens || []).map((entry) => ({
        token: entry.token,
        locale_code: 'ar',
      }));
    }
    const tokens = tokenRows.map((entry) => entry.token).filter(Boolean);
    if (tokens.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    if (seatKind && `${seatKind}`.toLowerCase() === 'extra') {
      if (`${seatStatus}`.toLowerCase() !== 'submitted') {
        res.status(200).json({ ok: true, skipped: 'seat_not_submitted' });
        return;
      }
    }

    const byLocale = groupTokensByLocale(tokenRows);
    const results = [];
    const isSeatRequest =
      seatKind && `${seatKind}`.toLowerCase() === 'extra';
    if (byLocale.ar.length > 0) {
      results.push(await sendFcm(byLocale.ar, buildPlanPayload({
        languageCode: 'ar',
        clinicName,
        planCode,
        employeeEmail,
        isSeatRequest,
      })));
    }
    if (byLocale.en.length > 0) {
      results.push(await sendFcm(byLocale.en, buildPlanPayload({
        languageCode: 'en',
        clinicName,
        planCode,
        employeeEmail,
        isSeatRequest,
      })));
    }
    const result = mergeSendResults(results);

    res.status(200).json({ ok: true, ...result });
  } catch (error) {
    res.status(200).json({ ok: false, error: `${error}` });
  }
};
