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
  resolveNotificationEventId,
  claimNotificationEvent,
  markNotificationDispatchStarted,
  completeNotificationEvent,
  failNotificationEvent,
} = require('../_shared/notify_utils');

const buildPayload = (languageCode, patientId, accountId) => {
  const locale = normalizeLanguageCode(languageCode);
  const title = locale === 'en' ? 'New patient case' : 'حالة مرضية جديدة';
  const body = locale === 'en'
    ? 'A patient record was added to your medical account.'
    : 'تمت إضافة حالة جديدة إلى حسابك الطبي.';
  const data = {
    type: 'patient',
    patient_id: String(patientId || ''),
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
  let claimedEventId = null;
  let claimToken = null;
  let dispatchCommitted = false;
  try {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'method_not_allowed' });
      return;
    }

    assertWebhookSecret(req);

    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const patientId = row.id;
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
      `query Doctor($id: uuid!) {
        doctors(where: {id: {_eq: $id}}, limit: 1) { user_uid account_id }
      }`,
      { id: doctorId },
    );
    const doctorUid = doctorData?.doctors?.[0]?.user_uid;
    const doctorAccountId = doctorData?.doctors?.[0]?.account_id;
    if (!doctorUid) {
      logInfo('PATIENT_NOTIFY_SKIPPED', ctx, { reason: 'no_doctor_uid' });
      res.status(200).json({ ok: true, skipped: 'no_doctor_uid' });
      return;
    }
    if (!doctorAccountId || (accountId && doctorAccountId !== accountId)) {
      res.status(200).json({ ok: true, skipped: 'account_mismatch' });
      return;
    }
    const access = await gqlRequest(
      `query ActiveDoctor($uid: uuid!, $account: uuid!) {
        account_users(where: {
          user_uid: {_eq: $uid}, account_id: {_eq: $account}, disabled: {_eq: false}
        }, limit: 1) { user_uid }
        user(id: $uid) { disabled }
      }`,
      { uid: doctorUid, account: doctorAccountId },
    );
    if (!access?.account_users?.length || access?.user?.disabled === true) {
      res.status(200).json({ ok: true, skipped: 'inactive_doctor' });
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

    claimedEventId = resolveNotificationEventId(
      payload,
      'notify-new-patient',
      patientId,
    );
    const claim = await claimNotificationEvent(
      claimedEventId,
      'notify-new-patient',
    );
    claimToken = claim.claimToken;
    if (!claim.claimed) {
      res.status(200).json({ ok: true, skipped: 'event_already_processed' });
      return;
    }
    await markNotificationDispatchStarted(claimedEventId, claimToken);
    dispatchCommitted = true;

    const byLocale = groupTokensByLocale(tokenRows);
    const results = [];
    if (byLocale.ar.length > 0) {
      results.push(
        await sendFcm(
          byLocale.ar,
          buildPayload('ar', patientId, accountId),
        ),
      );
    }
    if (byLocale.en.length > 0) {
      results.push(
        await sendFcm(
          byLocale.en,
          buildPayload('en', patientId, accountId),
        ),
      );
    }
    const result = mergeSendResults(results);
    await completeNotificationEvent(claimedEventId, claimToken, result);
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
    if (claimedEventId && claimToken && !dispatchCommitted) {
      await failNotificationEvent(
        claimedEventId,
        claimToken,
        toErrorString(e),
      );
    }
    const statusCode = Number(e?.statusCode || 500);
    const logFn = statusCode >= 500 ? logError : logWarn;
    logFn(statusCode >= 500 ? 'PATIENT_NOTIFY_UNHANDLED' : 'PATIENT_NOTIFY_REJECTED', ctx, {
      error: toErrorString(e),
    });
    res.status(statusCode).json({
      ok: false,
      error: statusCode >= 500 ? 'internal_error' : 'request_rejected',
      correlation_id: ctx.request_id,
    });
  }
};
