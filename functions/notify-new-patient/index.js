const {
  readBody,
  gqlRequest,
  sendFcm,
  groupTokensByLocale,
  mergeSendResults,
  normalizeLanguageCode,
} = require('../_shared/notify_utils');

const buildPayload = (languageCode, patientId, patientName) => {
  const locale = normalizeLanguageCode(languageCode);
  const safeName = patientName || (locale === 'en' ? 'New patient' : 'مريض جديد');
  const title = locale === 'en' ? 'New patient case' : 'حالة مرضية جديدة';
  const body = locale === 'en'
    ? `Patient ${safeName} was added to your medical account.`
    : `تم إضافة المريض ${safeName} إلى حسابك الطبي.`;
  return {
    notification: { title, body },
    data: {
      type: 'patient',
      patient_id: String(patientId || ''),
      patient_name: String(safeName || ''),
      title,
      body,
      payload: `patient:${patientId}`,
    },
  };
};

module.exports = async (req, res) => {
  try {
    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const patientId = row.id;
    const patientName = row.name || row.full_name || row.patient_name || '';
    const doctorId = row.doctor_id;

    if (!doctorId) {
      res.status(200).json({ ok: true, skipped: 'no_doctor' });
      return;
    }

    const doctorData = await gqlRequest(
      `query Doctor($id: Int!) {
        doctors(where: {id: {_eq: $id}}, limit: 1) { user_uid }
      }`,
      { id: doctorId },
    );
    const doctorUid = doctorData?.doctors?.[0]?.user_uid;
    if (!doctorUid) {
      res.status(200).json({ ok: true, skipped: 'no_doctor_uid' });
      return;
    }

    let tokenRows = [];
    try {
      const tokensData = await gqlRequest(
        `query Tokens($uid: uuid!) {
          push_device_tokens(
            where: {user_uid: {_eq: $uid}, is_active: {_eq: true}}
          ) { token locale_code }
        }`,
        { uid: doctorUid },
      );
      tokenRows = tokensData?.push_device_tokens || [];
    } catch (error) {
      if (!`${error}`.includes('locale_code')) throw error;
      const legacyTokens = await gqlRequest(
        `query TokensLegacy($uid: uuid!) {
          push_device_tokens(
            where: {user_uid: {_eq: $uid}, is_active: {_eq: true}}
          ) { token }
        }`,
        { uid: doctorUid },
      );
      tokenRows = (legacyTokens?.push_device_tokens || []).map((entry) => ({
        token: entry.token,
        locale_code: 'ar',
      }));
    }
    const tokens = tokenRows.map((t) => t.token).filter(Boolean);
    if (tokens.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const byLocale = groupTokensByLocale(tokenRows);
    const results = [];
    if (byLocale.ar.length > 0) {
      results.push(
        await sendFcm(byLocale.ar, buildPayload('ar', patientId, patientName)),
      );
    }
    if (byLocale.en.length > 0) {
      results.push(
        await sendFcm(byLocale.en, buildPayload('en', patientId, patientName)),
      );
    }
    const result = mergeSendResults(results);
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    res.status(200).json({ ok: false, error: `${e}` });
  }
};
