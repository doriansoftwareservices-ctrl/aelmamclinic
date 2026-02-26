const { readBody, gqlRequest, sendFcm } = require('../_shared/notify_utils');

const pickBody = (row) =>
  row?.body ||
  row?.text ||
  row?.message_body ||
  row?.message ||
  '';

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

    const tokensData = await gqlRequest(
      `query Tokens($uids: [uuid!]!) {
        push_device_tokens(
          where: {user_uid: {_in: $uids}, is_active: {_eq: true}}
        ) { token }
      }`,
      { uids: targetUids },
    );
    const tokens = (tokensData?.push_device_tokens || [])
      .map((t) => t.token)
      .filter(Boolean);

    if (tokens.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const body = pickBody(row);
    const title = 'رسالة جديدة';
    const data = {
      type: 'chat',
      conversation_id: conversationId,
      title,
      body: body || 'رسالة',
      payload: conversationId,
    };

    const result = await sendFcm(tokens, {
      notification: { title, body: body || 'رسالة' },
      data,
    });
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    res.status(200).json({ ok: false, error: `${e}` });
  }
};
