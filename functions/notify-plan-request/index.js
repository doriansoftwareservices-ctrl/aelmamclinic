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

const buildPlanPayload = ({
  languageCode,
  planCode,
  isSeatRequest,
  accountId,
  requestId,
}) => {
  const locale = normalizeLanguageCode(languageCode);
  let title = locale === 'en' ? 'New upgrade request' : 'طلب ترقية جديد';
  let body = locale === 'en'
    ? 'A new upgrade request was received.'
    : 'تم استلام طلب ترقية جديد.';
  let type = 'plan_request';
  let payload = 'admin:plan_request';

  if (isSeatRequest) {
    title = locale === 'en'
      ? 'Additional employee seat request'
      : 'طلب مقعد موظف إضافي';
    body = locale === 'en'
      ? 'An additional employee request was submitted'
      : 'تم إرسال طلب إضافة موظف إضافي';
    type = 'seat_request';
    payload = 'admin:seat_request';
  } else if (`${planCode || ''}`.toLowerCase() === 'trial_month') {
    title = locale === 'en'
      ? 'Monthly trial activation request'
      : 'طلب تفعيل الخطة التجريبية الشهرية';
    body = locale === 'en'
      ? 'A free monthly trial activation request was received.'
      : 'تم استلام طلب تفعيل تجريبي شهري مجاني.';
    type = 'trial_plan_request';
    payload = 'admin:trial_plan_request';
  }

  return {
    notification: { title, body },
    data: {
      type,
      title,
      body,
      payload,
      account_id: accountId ? String(accountId) : '',
      request_id: requestId ? String(requestId) : '',
    },
  };
};

module.exports = async (req, res) => {
  const ctx = makeRequestContext(req, 'notify-plan-request');
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
    const requestId = row.id || null;
    const accountId = row.account_id || null;
    const planCode = row.plan_code || row.planCode || '';
    const seatKind = row.seat_kind || row.seatKind || '';
    const seatStatus = row.status || '';
    logInfo('PLAN_NOTIFY_REQUEST_RECEIVED', ctx, {
      request_id: requestId || '',
      account_id: accountId || '',
      plan_code: planCode || '',
      seat_kind: seatKind || '',
      status: seatStatus || '',
    });

    const admins = await gqlRequest(
      `query { super_admins(where: {disabled: {_eq: false}}) { user_uid } }`,
      {},
    );
    const candidateUids = (admins?.super_admins || [])
      .map((entry) => entry.user_uid)
      .filter(Boolean);
    const activeUsers = candidateUids.length === 0
      ? { users: [] }
      : await gqlRequest(
          `query ActiveAdmins($uids: [uuid!]!) {
            users(where: {id: {_in: $uids}, disabled: {_eq: false}}) { id }
          }`,
          { uids: candidateUids },
        );
    const uids = (activeUsers?.users || []).map((entry) => entry.id).filter(Boolean);
    if (uids.length === 0) {
      logInfo('PLAN_NOTIFY_SKIPPED', ctx, { reason: 'no_admins' });
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
      logWarn('PLAN_NOTIFY_LOCALE_FALLBACK', ctx, {
        reason: 'tokens_query_locale_missing',
        error: toErrorString(error),
      });
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
      logInfo('PLAN_NOTIFY_SKIPPED', ctx, { reason: 'no_tokens' });
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    if (seatKind && `${seatKind}`.toLowerCase() === 'extra') {
      if (`${seatStatus}`.toLowerCase() !== 'submitted') {
        logInfo('PLAN_NOTIFY_SKIPPED', ctx, { reason: 'seat_not_submitted' });
        res.status(200).json({ ok: true, skipped: 'seat_not_submitted' });
        return;
      }
    }

    claimedEventId = resolveNotificationEventId(
      payload,
      'notify-plan-request',
      requestId,
    );
    const claim = await claimNotificationEvent(
      claimedEventId,
      'notify-plan-request',
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
    const isSeatRequest =
      seatKind && `${seatKind}`.toLowerCase() === 'extra';
    if (byLocale.ar.length > 0) {
      results.push(await sendFcm(byLocale.ar, buildPlanPayload({
        languageCode: 'ar',
        planCode,
        isSeatRequest,
        accountId,
        requestId,
      })));
    }
    if (byLocale.en.length > 0) {
      results.push(await sendFcm(byLocale.en, buildPlanPayload({
        languageCode: 'en',
        planCode,
        isSeatRequest,
        accountId,
        requestId,
      })));
    }
    const result = mergeSendResults(results);
    await completeNotificationEvent(claimedEventId, claimToken, result);
    logInfo('PLAN_NOTIFY_SENT', ctx, {
      request_id: requestId || '',
      account_id: accountId || '',
      tokens: tokens.length,
      sent: Number(result.sent || 0),
      failed: Number(result.failed || 0),
      deactivated: Number(result.deactivated || 0),
    });

    res.status(200).json({ ok: true, ...result });
  } catch (error) {
    if (claimedEventId && claimToken && !dispatchCommitted) {
      await failNotificationEvent(
        claimedEventId,
        claimToken,
        toErrorString(error),
      );
    }
    const statusCode = Number(error?.statusCode || 500);
    const logFn = statusCode >= 500 ? logError : logWarn;
    logFn(statusCode >= 500 ? 'PLAN_NOTIFY_UNHANDLED' : 'PLAN_NOTIFY_REJECTED', ctx, {
      error: toErrorString(error),
    });
    res.status(statusCode).json({
      ok: false,
      error: statusCode >= 500 ? 'internal_error' : 'request_rejected',
      correlation_id: ctx.request_id,
    });
  }
};
