'use strict';
// Existing Hasura hooks are wakeups only. Source transactions capture v2
// events; this path never derives recipients or retries a v1 completed event.
module.exports = require('../notify-dispatch-v2');
