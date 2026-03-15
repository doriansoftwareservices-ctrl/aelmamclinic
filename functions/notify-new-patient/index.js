const {
  readBody,
  gqlRequest,
  sendFcm,
  groupTokensByLocale,
  mergeSendResults,
  normalizeLanguageCode,
  makeRequestContext,
  assertWebhookSecret,
  logInfo,
  logWarn,
  logError,
  toErrorString,
} = require('../_shared/notify_utils');

const buildPayload = (languageCode, patientId, patientName, accountId) => {
  const locale = normalizeLanguageCode(languageCode);
  const safeName = patientName || (locale === 'en' ? 'New patient' : 'مريض جديد');
  const title = locale === 'en' ? 'New patient case' : 'حالة مرضية جديدة';
  const body = locale === 'en'
    ? `Patient ${safeName} was added to your medical account.`
    : `تم إضافة المريض ${safeName} إلى حسابك الطبي.`;
  const data = {
    type: 'patient',
    patient_id: String(patientId || ''),
    patient_name: String(safeName || ''),
    title,
    body,
    payload: `patient:${patientId}`,
  };
  if (accountId) {
    data.account_id = String(accountId);
  }
  return {
    notification: { title, body },
    data,
  };
};

module.exports = async (req, res) => {
  const ctx = makeRequestContext(req, 'notify-new-patient');
  try {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'method_not_allowed' });
      return;
    }

    assertWebhookSecret(req);

    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const patientId = row.id;
    const patientName = row.name || row.full_name || row.patient_name || '';
    const doctorId = row.doctor_id;
    const accountId = row.account_id || null;
    logInfo('PATIENT_NOTIFY_REQUEST_RECEIVED', ctx, {
      patient_id: patientId || '',
      doctor_id: doctorId || '',
      account_id: accountId || '',
    });

    if (!doctorId) {
      logInfo('PATIENT_NOTIFY_SKIPPED', ctx, { reason: 'no_doctor' });
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
      logInfo('PATIENT_NOTIFY_SKIPPED', ctx, { reason: 'no_doctor_uid' });
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
      logWarn('PATIENT_NOTIFY_LOCALE_FALLBACK', ctx, {
        reason: 'tokens_query_locale_missing',
        error: toErrorString(error),
      });
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
      logInfo('PATIENT_NOTIFY_SKIPPED', ctx, { reason: 'no_tokens' });
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const byLocale = groupTokensByLocale(tokenRows);
    const results = [];
    if (byLocale.ar.length > 0) {
      results.push(
        await sendFcm(
          byLocale.ar,
          buildPayload('ar', patientId, patientName, accountId),
        ),
      );
    }
    if (byLocale.en.length > 0) {
      results.push(
        await sendFcm(
          byLocale.en,
          buildPayload('en', patientId, patientName, accountId),
        ),
      );
    }
    const result = mergeSendResults(results);
    logInfo('PATIENT_NOTIFY_SENT', ctx, {
      patient_id: patientId || '',
      doctor_uid: doctorUid,
      tokens: tokens.length,
      sent: Number(result.sent || 0),
      failed: Number(result.failed || 0),
      deactivated: Number(result.deactivated || 0),
    });
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    const statusCode = Number(e?.statusCode || 500);
    const logFn = statusCode >= 500 ? logError : logWarn;
    logFn(statusCode >= 500 ? 'PATIENT_NOTIFY_UNHANDLED' : 'PATIENT_NOTIFY_REJECTED', ctx, {
      error: toErrorString(e),
    });
    res.status(statusCode).json({ ok: false, error: e?.message || 'internal_error' });
  }
};
