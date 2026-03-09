const {
  readBody,
  gqlRequest,
  sendFcm,
  groupTokensByLocale,
  mergeSendResults,
  normalizeLanguageCode,
} = require('../_shared/notify_utils');

const pickBody = (row) =>
  row?.body ||
  row?.text ||
  row?.message_body ||
  row?.message ||
  '';

const buildPayload = (languageCode, conversationId, body) => {
  const locale = normalizeLanguageCode(languageCode);
  const title = locale === 'en' ? 'New message' : 'رسالة جديدة';
  const safeBody = body || (locale === 'en' ? 'Message' : 'رسالة');
  return {
    notification: {
      title,
      body: safeBody,
    },
    data: {
      type: 'chat',
      conversation_id: conversationId,
      title,
      body: safeBody,
      payload: conversationId,
    },
  };
};

module.exports = async (req, res) => {
  try {
    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const conversationId = row.conversation_id;
    const senderUid = row.sender_uid;
    if (!conversationId || !senderUid) {
      res.status(200).json({ ok: true, skipped: 'missing_fields' });
      return;
    }

    const supportData = await gqlRequest(
      `query SupportAgent { chat_support_agent { user_uid display_name } }`,
      {},
    );
    const supportUid = supportData?.chat_support_agent?.[0]?.user_uid || null;

    const partsData = await gqlRequest(
      `query Parts($cid: uuid!) {
        chat_participants(where: {conversation_id: {_eq: $cid}}) {
          user_uid
        }
      }`,
      { cid: conversationId },
    );
    const participants = (partsData?.chat_participants || [])
      .map((p) => p.user_uid)
      .filter(Boolean);

    let targetUids = participants.filter((u) => u !== senderUid);

    // إذا كانت محادثة خدمة العملاء -> أرسل إلى كل السوبر أدمن
    if (supportUid && participants.includes(supportUid) && senderUid !== supportUid) {
      const sa = await gqlRequest(`query { super_admins { user_uid } }`, {});
      targetUids = (sa?.super_admins || [])
        .map((s) => s.user_uid)
        .filter(Boolean);
    }

    if (targetUids.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_targets' });
      return;
    }

    // استبعاد المؤرشفة (صامتة حتى مع إغلاق التطبيق)
    try {
      const prefs = await gqlRequest(
        `query Prefs($cid: uuid!, $uids: [uuid!]!) {
          chat_participants(
            where: {conversation_id: {_eq: $cid}, user_uid: {_in: $uids}}
          ) {
            user_uid
            archived
          }
        }`,
        { cid: conversationId, uids: targetUids },
      );
      const archivedSet = new Set(
        (prefs?.chat_participants || [])
          .filter((p) => p.archived === true || p.archived === 1)
          .map((p) => p.user_uid)
          .filter(Boolean),
      );
      if (archivedSet.size > 0) {
        targetUids = targetUids.filter((u) => !archivedSet.has(u));
      }
    } catch (_) {}

    if (targetUids.length === 0) {
      res.status(200).json({ ok: true, skipped: 'archived_targets' });
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
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const body = pickBody(row);
    const byLocale = groupTokensByLocale(tokenRows);
    const results = [];
    if (byLocale.ar.length > 0) {
      results.push(await sendFcm(byLocale.ar, buildPayload('ar', conversationId, body)));
    }
    if (byLocale.en.length > 0) {
      results.push(await sendFcm(byLocale.en, buildPayload('en', conversationId, body)));
    }
    const result = mergeSendResults(results);
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    res.status(200).json({ ok: false, error: `${e}` });
  }
};
