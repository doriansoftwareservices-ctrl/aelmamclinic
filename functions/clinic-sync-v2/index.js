const {readBody} = require('../_shared/storage_utils');
const sync = require('../clinic-sync');

// A distinct route prevents older deployed handlers from silently ignoring a
// version precondition. Missing v2 deployments fail without any domain write.
module.exports = async function versionedSync(req, res) {
  if (req.method && req.method.toUpperCase() !== 'POST') {
    res.status(405).json({success: false, error_code: 'method_not_allowed'});
    return;
  }
  let body;
  try { body = await readBody(req); } catch (_) {
    res.status(400).json({success: false, error_code: 'invalid_sync_protocol'});
    return;
  }
  if (!body || body.sync_protocol !== 2 || body.operation_type === 'amend_purchase') {
    res.status(400).json({success: false, error_code: 'invalid_sync_protocol'});
    return;
  }
  const forwarded = Object.create(req);
  forwarded.body = body;
  await sync(forwarded, res);
};
