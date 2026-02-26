const { readBody, gqlRequest, sendFcm } = require('../_shared/notify_utils');

module.exports = async (req, res) => {
  try {
    const payload = await readBody(req);
    const row = payload?.event?.data?.new || payload?.data?.new || {};
    const patientId = row.id;
    const patientName = row.name || row.full_name || row.patient_name || 'مريض جديد';
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

    const tokensData = await gqlRequest(
      `query Tokens($uid: uuid!) {
        push_device_tokens(
          where: {user_uid: {_eq: $uid}, is_active: {_eq: true}}
        ) { token }
      }`,
      { uid: doctorUid },
    );
    const tokens = (tokensData?.push_device_tokens || [])
      .map((t) => t.token)
      .filter(Boolean);
    if (tokens.length === 0) {
      res.status(200).json({ ok: true, skipped: 'no_tokens' });
      return;
    }

    const title = 'حالة مرضية جديدة';
    const body = `تم إضافة المريض ${patientName} إلى حسابك الطبي.`;
    const data = {
      type: 'patient',
      patient_id: String(patientId || ''),
      patient_name: String(patientName || ''),
      title,
      body,
      payload: `patient:${patientId}`,
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
