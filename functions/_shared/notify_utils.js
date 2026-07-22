const crypto = require('crypto');

const nowIso = () => new Date().toISOString();

const toErrorString = (error) => {
  if (!error) return '';
  if (typeof error === 'string') return 'operation_failed';
  if (error instanceof Error) {
    return `${error.code || error.name || 'operation_failed'}`;
  }
  return 'operation_failed';
};

const makeRequestContext = (req, eventType) => {
  const headers = req?.headers || {};
  const headerId =
    headers['x-request-id'] ||
    headers['x-correlation-id'] ||
    headers['x-amzn-trace-id'] ||
    headers['traceparent'];
  const requestId =
    headerId ||
    (typeof crypto.randomUUID === 'function'
      ? crypto.randomUUID()
      : `req_${Date.now()}_${Math.random().toString(16).slice(2)}`);
  return {
    request_id: `${requestId}`,
    event_type: `${eventType || 'unknown'}`,
  };
};

const emitLog = (level, code, context = {}, details = {}) => {
  const payload = {
    ts: nowIso(),
    level,
    code,
    ...context,
    details,
  };
  const text = JSON.stringify(payload);
  if (level === 'error') {
    console.error(text);
    return;
  }
  if (level === 'warn') {
    console.warn(text);
    return;
  }
  console.log(text);
};

const logInfo = (code, context = {}, details = {}) =>
  emitLog('info', code, context, details);
const logWarn = (code, context = {}, details = {}) =>
  emitLog('warn', code, context, details);
const logError = (code, context = {}, details = {}) =>
  emitLog('error', code, context, details);

const readBody = (req) =>
  new Promise((resolve) => {
    if (req.body && typeof req.body === 'object') {
      resolve(req.body);
      return;
    }
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
    });
    req.on('end', () => {
      if (!data) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(data));
      } catch (_) {
        resolve({});
      }
    });
  });

const getHeaderInsensitive = (req, name) => {
  const headers = req?.headers || {};
  const target = `${name || ''}`.toLowerCase();
  for (const [key, value] of Object.entries(headers)) {
    if (`${key}`.toLowerCase() === target) {
      return Array.isArray(value) ? value[0] : value;
    }
  }
  return undefined;
};

const resolveWebhookSecret = () =>
  `${process.env.HASURA_EVENT_SECRET || process.env.NHOST_WEBHOOK_SECRET || process.env.WEBHOOK_SECRET || ''}`.trim();

const timingSafeEqualText = (left, right) => {
  const leftBuf = Buffer.from(`${left || ''}`);
  const rightBuf = Buffer.from(`${right || ''}`);
  if (leftBuf.length !== rightBuf.length) {
    return false;
  }
  return crypto.timingSafeEqual(leftBuf, rightBuf);
};

const assertWebhookSecret = (req) => {
  const expected = resolveWebhookSecret();
  if (!expected) {
    const error = new Error('webhook_secret_not_configured');
    error.statusCode = 500;
    throw error;
  }

  const provided = `${getHeaderInsensitive(req, 'x-hasura-event-secret') ||
    getHeaderInsensitive(req, 'x-webhook-secret') ||
    ''}`.trim();

  if (!provided) {
    const error = new Error('missing_webhook_secret');
    error.statusCode = 401;
    throw error;
  }

  if (!timingSafeEqualText(provided, expected)) {
    const error = new Error('invalid_webhook_secret');
    error.statusCode = 403;
    throw error;
  }
};

const normalizeGraphqlUrl = (raw) => {
  if (!raw) return null;
  let url = raw.replace(/\/+$/, '');
  if (url.endsWith('/v1/graphql')) return url;
  if (url.endsWith('/graphql')) return url.replace(/\/graphql$/, '/v1/graphql');
  if (url.endsWith('.nhost.run')) return `${url}/v1/graphql`;
  if (url.includes('.graphql.')) {
    url = url.replace(/\/v1$/i, '');
    return `${url}/v1/graphql`;
  }
  return null;
};

const resolveGraphqlUrl = () => {
  const candidates = [
    process.env.NHOST_GRAPHQL_URL,
    process.env.HASURA_GRAPHQL_URL,
    process.env.NHOST_BACKEND_URL,
  ];
  for (const raw of candidates) {
    const url = normalizeGraphqlUrl(raw);
    if (url) return url;
  }
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.graphql.${region}.nhost.run/v1/graphql`;
  }
  return null;
};

const adminHeaders = () => {
  const adminSecret =
    process.env.GRAPHQL_ADMIN_SECRET ||
    process.env.NHOST_ADMIN_SECRET ||
    process.env.HASURA_GRAPHQL_ADMIN_SECRET;
  if (!adminSecret) {
    throw new Error('Missing GRAPHQL_ADMIN_SECRET');
  }
  return {
    'Content-Type': 'application/json',
    'x-hasura-admin-secret': adminSecret,
  };
};

async function gqlRequest(query, variables = {}) {
  const url = resolveGraphqlUrl();
  if (!url) throw new Error('Missing GraphQL URL');
  const res = await fetch(url, {
    method: 'POST',
    headers: adminHeaders(),
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) {
    const error = new Error('graphql_request_failed');
    error.code = 'graphql_request_failed';
    throw error;
  }
  return json.data || {};
}

const resolveNotificationEventId = (payload, eventType, rowId) => {
  const deliveredEventId =
    payload?.id || payload?.event?.id || payload?.event_id || '';
  const table = payload?.table || payload?.event?.table || {};
  const operation = payload?.event?.op || payload?.op || 'INSERT';
  const source = `${table.schema || 'public'}.${table.name || 'unknown'}`;
  const stableIdentity = `${deliveredEventId || rowId || ''}`.trim();
  if (!stableIdentity) {
    const error = new Error('missing_notification_event_identity');
    error.statusCode = 400;
    throw error;
  }
  const seed = deliveredEventId
    ? `hasura:${eventType}:${stableIdentity}`
    : `fallback:${eventType}:${source}:${operation}:${stableIdentity}`;
  return `nev1_${crypto.createHash('sha256').update(seed).digest('hex')}`;
};

const newClaimToken = () =>
  typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : crypto.randomBytes(16).toString('hex');

async function claimNotificationEvent(eventId, eventType) {
  const claimToken = newClaimToken();
  const data = await gqlRequest(
    `mutation ClaimNotificationEvent(
      $eventId: String!,
      $eventType: String!,
      $claimToken: String!
    ) {
      claim_notification_event(args: {
        p_event_id: $eventId,
        p_event_type: $eventType,
        p_claim_token: $claimToken
      }) {
        event_id
        claim_token
      }
    }`,
    { eventId, eventType, claimToken },
  );
  const row = data?.claim_notification_event?.[0];
  return {
    claimed: row?.event_id === eventId && row?.claim_token === claimToken,
    claimToken,
  };
}

const notificationResultSummary = (result = {}) => ({
  sent: Number(result.sent || 0),
  failed: Number(result.failed || 0),
  deactivated: Number(result.deactivated || 0),
  ...(result.skipped ? { skipped: `${result.skipped}` } : {}),
});

async function markNotificationDispatchStarted(eventId, claimToken) {
  const completedAt = nowIso();
  const data = await gqlRequest(
    `mutation MarkNotificationDispatchStarted(
      $eventId: String!,
      $claimToken: String!,
      $completedAt: timestamptz!,
      $summary: jsonb!
    ) {
      update_notification_event_deliveries(
        where: {
          event_id: {_eq: $eventId},
          claim_token: {_eq: $claimToken},
          status: {_eq: "processing"}
        },
        _set: {
          status: "completed",
          lease_until: null,
          completed_at: $completedAt,
          updated_at: $completedAt,
          result_summary: $summary,
          last_error_code: null
        }
      ) { affected_rows }
    }`,
    {
      eventId,
      claimToken,
      completedAt,
      summary: { dispatch_started: true },
    },
  );
  if (data?.update_notification_event_deliveries?.affected_rows !== 1) {
    throw new Error('notification_claim_lost');
  }
}

async function completeNotificationEvent(eventId, claimToken, result) {
  const updatedAt = nowIso();
  await gqlRequest(
    `mutation CompleteNotificationEvent(
      $eventId: String!,
      $claimToken: String!,
      $updatedAt: timestamptz!,
      $summary: jsonb!
    ) {
      update_notification_event_deliveries(
        where: {
          event_id: {_eq: $eventId},
          claim_token: {_eq: $claimToken},
          status: {_eq: "completed"}
        },
        _set: {updated_at: $updatedAt, result_summary: $summary}
      ) { affected_rows }
    }`,
    {
      eventId,
      claimToken,
      updatedAt,
      summary: notificationResultSummary(result),
    },
  );
}

async function failNotificationEvent(eventId, claimToken, errorCode) {
  if (!eventId || !claimToken) return;
  const updatedAt = nowIso();
  try {
    await gqlRequest(
      `mutation FailNotificationEvent(
        $eventId: String!,
        $claimToken: String!,
        $updatedAt: timestamptz!,
        $errorCode: String!
      ) {
        update_notification_event_deliveries(
          where: {
            event_id: {_eq: $eventId},
            claim_token: {_eq: $claimToken},
            status: {_eq: "processing"}
          },
          _set: {
            status: "failed",
            lease_until: null,
            updated_at: $updatedAt,
            last_error_code: $errorCode
          }
        ) { affected_rows }
      }`,
      {
        eventId,
        claimToken,
        updatedAt,
        errorCode: `${errorCode || 'notification_failed'}`.slice(0, 80),
      },
    );
  } catch (_) {
    // Preserve the original failure. The lease still makes the claim recoverable.
  }
}

const INVALID_FCM_V1_ERRORS = new Set([
  'UNREGISTERED',
  'SENDER_ID_MISMATCH',
  'NOT_FOUND',
]);

let cachedFcmAccessToken = null;
let cachedFcmAccessTokenExpiryMs = 0;

const normalizeTokens = (tokens) =>
  [...new Set((tokens || [])
    .map((token) => `${token || ''}`.trim())
    .filter(Boolean))];

const normalizeLanguageCode = (raw) => {
  const value = `${raw || ''}`.trim().toLowerCase();
  return value === 'en' ? 'en' : 'ar';
};

const groupTokensByLocale = (rows) => {
  const grouped = { ar: [], en: [] };
  for (const row of rows || []) {
    const token = `${row?.token || ''}`.trim();
    if (!token) continue;
    const languageCode = normalizeLanguageCode(row?.locale_code);
    grouped[languageCode].push(token);
  }
  grouped.ar = normalizeTokens(grouped.ar);
  grouped.en = normalizeTokens(grouped.en);
  return grouped;
};

const mergeSendResults = (results) => {
  const summary = {
    sent: 0,
    failed: 0,
    deactivated: 0,
  };
  for (const result of results || []) {
    if (!result || typeof result !== 'object') continue;
    summary.sent += Number(result.sent || 0);
    summary.failed += Number(result.failed || 0);
    summary.deactivated += Number(result.deactivated || 0);
    if (result.skipped && !summary.skipped) {
      summary.skipped = result.skipped;
    }
  }
  return summary;
};

async function deactivatePushTokens(tokens) {
  const uniqueTokens = normalizeTokens(tokens);
  if (uniqueTokens.length === 0) {
    return { affectedRows: 0 };
  }
  try {
    const data = await gqlRequest(
      `mutation DeactivatePushTokens($tokens: [String!]!) {
        update_push_device_tokens(
          where: {token: {_in: $tokens}}
          _set: {is_active: false}
        ) {
          affected_rows
        }
      }`,
      { tokens: uniqueTokens },
    );
    return {
      affectedRows: data?.update_push_device_tokens?.affected_rows || 0,
    };
  } catch (error) {
    return {
      affectedRows: 0,
      error: `${error}`,
    };
  }
}

const base64UrlEncode = (value) =>
  Buffer.from(value)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');

const normalizePrivateKey = (raw) =>
  `${raw || ''}`.replace(/\\n/g, '\n').trim();

const resolveFirebaseServiceAccount = () => {
  const jsonCandidates = [
    process.env.FIREBASE_SERVICE_ACCOUNT_JSON,
    process.env.GOOGLE_SERVICE_ACCOUNT_JSON,
    process.env.GCP_SERVICE_ACCOUNT_JSON,
  ];
  for (const raw of jsonCandidates) {
    if (!raw || !`${raw}`.trim()) continue;
    try {
      const parsed = JSON.parse(raw);
      if (parsed?.client_email && parsed?.private_key && parsed?.project_id) {
        return {
          clientEmail: `${parsed.client_email}`.trim(),
          privateKey: normalizePrivateKey(parsed.private_key),
          projectId: `${parsed.project_id}`.trim(),
        };
      }
    } catch (_) {}
  }

  const clientEmail = `${
    process.env.FIREBASE_CLIENT_EMAIL ||
    process.env.GOOGLE_CLIENT_EMAIL ||
    ''
  }`.trim();
  const privateKey = normalizePrivateKey(
    process.env.FIREBASE_PRIVATE_KEY || process.env.GOOGLE_PRIVATE_KEY || '',
  );
  const projectId = `${
    process.env.FIREBASE_PROJECT_ID ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCLOUD_PROJECT ||
    ''
  }`.trim();

  if (!clientEmail || !privateKey || !projectId) {
    return null;
  }

  return {
    clientEmail,
    privateKey,
    projectId,
  };
};

const buildGoogleAuthAssertion = (serviceAccount) => {
  const now = Math.floor(Date.now() / 1000);
  const header = {
    alg: 'RS256',
    typ: 'JWT',
  };
  const claim = {
    iss: serviceAccount.clientEmail,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };

  const unsignedToken = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(
    JSON.stringify(claim),
  )}`;
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(unsignedToken);
  signer.end();
  const signature = signer.sign(serviceAccount.privateKey);
  return `${unsignedToken}.${base64UrlEncode(signature)}`;
};

async function getFcmAccessToken() {
  const serviceAccount = resolveFirebaseServiceAccount();
  if (!serviceAccount) {
    return {
      accessToken: null,
      projectId: null,
      skipped: 'missing_firebase_service_account',
    };
  }

  if (
    cachedFcmAccessToken &&
    cachedFcmAccessTokenExpiryMs > Date.now() + 60 * 1000
  ) {
    return {
      accessToken: cachedFcmAccessToken,
      projectId: serviceAccount.projectId,
    };
  }

  const assertion = buildGoogleAuthAssertion(serviceAccount);
  const body = new URLSearchParams({
    grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    assertion,
  });

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body.toString(),
  });

  const text = await response.text();
  let json = {};
  if (text) {
    try {
      json = JSON.parse(text);
    } catch (_) {
      json = { raw: text };
    }
  }

  if (!response.ok || !json.access_token) {
    throw new Error(
      `fcm_access_token_request_failed: HTTP ${response.status}: ${text || 'empty response'}`,
    );
  }

  cachedFcmAccessToken = `${json.access_token}`;
  cachedFcmAccessTokenExpiryMs =
    Date.now() + Math.max(Number(json.expires_in || 3600) - 60, 60) * 1000;

  return {
    accessToken: cachedFcmAccessToken,
    projectId: serviceAccount.projectId,
  };
}

const stringifyDataPayload = (data) => {
  const out = {};
  for (const [key, value] of Object.entries(data || {})) {
    out[key] = value == null ? '' : `${value}`;
  }
  return out;
};

const resolveFcmV1ErrorCode = (json) => {
  const topLevel = `${json?.error?.status || ''}`.trim().toUpperCase();
  const details = Array.isArray(json?.error?.details) ? json.error.details : [];
  for (const entry of details) {
    const errorCode = `${entry?.errorCode || ''}`.trim().toUpperCase();
    if (errorCode) return errorCode;
  }
  return topLevel;
};

const isInvalidFcmTokenError = (errorCode, rawText) => {
  const normalizedCode = `${errorCode || ''}`.trim().toUpperCase();
  if (INVALID_FCM_V1_ERRORS.has(normalizedCode)) {
    return true;
  }
  if (normalizedCode !== 'INVALID_ARGUMENT') {
    return false;
  }
  const text = `${rawText || ''}`.toLowerCase();
  return text.includes('registration token') || text.includes('unregistered');
};

const buildFcmV1Message = (token, payload) => ({
  message: {
    token,
    notification: payload.notification || undefined,
    data: stringifyDataPayload(payload.data),
    android: {
      priority: 'HIGH',
    },
    apns: {
      headers: {
        'apns-priority': '10',
      },
      payload: {
        aps: {
          sound: 'default',
        },
      },
    },
  },
});

async function sendSingleFcmV1({ accessToken, projectId, token, payload }) {
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(buildFcmV1Message(token, payload)),
    },
  );

  const text = await response.text();
  let json = {};
  if (text) {
    try {
      json = JSON.parse(text);
    } catch (_) {
      json = { raw: text };
    }
  }

  if (response.ok) {
    return {
      sent: 1,
      failed: 0,
      invalidToken: null,
      error: null,
    };
  }

  const errorCode = resolveFcmV1ErrorCode(json);
  return {
    sent: 0,
    failed: 1,
    invalidToken: isInvalidFcmTokenError(errorCode, text) ? token : null,
    error: `HTTP ${response.status} ${errorCode || 'FCM_ERROR'}: ${text || 'empty response'}`,
  };
}

async function sendFcm(tokens, payload) {
  const uniqueTokens = normalizeTokens(tokens);
  if (uniqueTokens.length === 0) {
    return { sent: 0, skipped: 'no_tokens' };
  }

  let accessTokenData;
  try {
    accessTokenData = await getFcmAccessToken();
  } catch (error) {
    return {
      sent: 0,
      failed: uniqueTokens.length,
      errors: [`${error}`],
    };
  }

  if (!accessTokenData?.accessToken || !accessTokenData?.projectId) {
    return {
      sent: 0,
      skipped: accessTokenData?.skipped || 'missing_fcm_v1_credentials',
    };
  }

  let sent = 0;
  let failed = 0;
  const invalidTokens = [];
  const requestErrors = [];
  const chunkSize = 20;

  for (let i = 0; i < uniqueTokens.length; i += chunkSize) {
    const slice = uniqueTokens.slice(i, i + chunkSize);
    const sliceResults = await Promise.all(
      slice.map((token) =>
        sendSingleFcmV1({
          accessToken: accessTokenData.accessToken,
          projectId: accessTokenData.projectId,
          token,
          payload,
        }),
      ),
    );

    for (const result of sliceResults) {
      sent += Number(result.sent || 0);
      failed += Number(result.failed || 0);
      if (result.invalidToken) {
        invalidTokens.push(result.invalidToken);
      }
      if (result.error) {
        requestErrors.push(result.error);
      }
    }
  }

  const cleanup = await deactivatePushTokens(invalidTokens);
  const result = {
    sent,
    failed,
    deactivated: cleanup.affectedRows || 0,
  };
  if (cleanup.error) {
    result.cleanupError = cleanup.error;
  }
  if (requestErrors.length > 0) {
    result.errors = requestErrors;
  }
  return result;
}

module.exports = {
  readBody,
  gqlRequest,
  sendFcm,
  deactivatePushTokens,
  normalizeLanguageCode,
  groupTokensByLocale,
  mergeSendResults,
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
};
