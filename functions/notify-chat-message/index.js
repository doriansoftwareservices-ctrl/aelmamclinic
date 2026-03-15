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

const pickBody = (row) =>
  row?.body ||
  row?.text ||
  row?.message_body ||
  row?.message ||
  '';

const buildPayload = (languageCode, conversationId, body, accountId) => {
  const locale = normalizeLanguageCode(languageCode);
  const title = locale === 'en' ? 'New message' : 'رسالة جديدة';
  const safeBody = body || (locale === 'en' ? 'Message' : 'رسالة');
  const data = {
    type: 'chat',
    conversation_id: conversationId,
    title,
    body: safeBody,
    payload: conversationId,
  };
  if (accountId) {
    data.account_id = String(accountId);
  }
  return {
    notification: {
      title,
      body: safeBody,
    },
    data,
  };
};

module.exports = async (req, res) => {
  const ctx = makeRequestContext(req, 'notify-chat-message');
  try {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'method_not_allowed' });
      return;
    }

    assertWebhookSecret(req);

    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const conversationId = row.conversation_id;
    const senderUid = row.sender_uid;
    const accountId = row.account_id || null;
    logInfo('CHAT_NOTIFY_REQUEST_RECEIVED', ctx, {
      conversation_id: conversationId || '',
      sender_uid: senderUid || '',
      account_id: accountId || '',
    });
    if (!conversationId || !senderUid) {
      logInfo('CHAT_NOTIFY_SKIPPED', ctx, { reason: 'missing_fields' });
      res.status(200).json({ ok: true, skipped: 'missing_fields' });
      return;
    }

    const partsData = await gqlRequest(
      `query Parts($cid: uuid!) {
        chat_participants(
          where: {
            conversation_id: {_eq: $cid},
            _or: [{is_deleted: {_eq: false}}, {is_deleted: {_is_null: true}}]
          }
        ) {
          user_uid
          archived
          muted
        }
      }`,
      { cid: conversationId },
    );
    const participantRows = (partsData?.chat_participants || []).filter(Boolean);
    const isSuppressed = (value) => value === true || value === 1;
    let targetUids = participantRows
      .filter((participant) => participant.user_uid && participant.user_uid !== senderUid)
      .filter((participant) => !isSuppressed(participant.archived))
      .filter((participant) => !isSuppressed(participant.muted))
      .map((participant) => participant.user_uid)
      .filter(Boolean);

    if (targetUids.length === 0) {
      logInfo('CHAT_NOTIFY_SKIPPED', ctx, { reason: 'no_targets' });
      res.status(200).json({ ok: true, skipped: 'no_targets' });
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
        { uids: targetUids },
      );
      tokenRows = tokensData?.push_device_tokens || [];
    } catch (error) {
      logWarn('CHAT_NOTIFY_LOCALE_FALLBACK', ctx, {
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
        { uids: targetUids },
      );
      tokenRows = (legacyTokens?.push_device_tokens || []).map((entry) => ({
        token: entry.token,
        locale_code: 'ar',
      }));
    }
    const tokens = tokenRows.map((t) => t.token).filter(Boolean);

    if (tokens.length === 0) {
      logInfo('CHAT_NOTIFY_SKIPPED', ctx, { reason: 'no_tokens' });
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const body = pickBody(row);
    const byLocale = groupTokensByLocale(tokenRows);
    const results = [];
    if (byLocale.ar.length > 0) {
      results.push(
        await sendFcm(
          byLocale.ar,
          buildPayload('ar', conversationId, body, accountId),
        ),
      );
    }
    if (byLocale.en.length > 0) {
      results.push(
        await sendFcm(
          byLocale.en,
          buildPayload('en', conversationId, body, accountId),
        ),
      );
    }
    const result = mergeSendResults(results);
    logInfo('CHAT_NOTIFY_SENT', ctx, {
      conversation_id: conversationId,
      target_uids: targetUids.length,
      tokens: tokens.length,
      sent: Number(result.sent || 0),
      failed: Number(result.failed || 0),
      deactivated: Number(result.deactivated || 0),
    });
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    const statusCode = Number(e?.statusCode || 500);
    const logFn = statusCode >= 500 ? logError : logWarn;
    logFn(statusCode >= 500 ? 'CHAT_NOTIFY_UNHANDLED' : 'CHAT_NOTIFY_REJECTED', ctx, {
      error: toErrorString(e),
    });
    res.status(statusCode).json({ ok: false, error: e?.message || 'internal_error' });
  }
};
