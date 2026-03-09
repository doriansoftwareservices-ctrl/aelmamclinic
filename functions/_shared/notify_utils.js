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
    process.env.HASURA_GRAPHQL_ADMIN_SECRET ||
    process.env.NHOST_WEBHOOK_SECRET;
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
    throw new Error(JSON.stringify(json.errors));
  }
  return json.data || {};
}

const INVALID_FCM_ERRORS = new Set([
  'InvalidRegistration',
  'NotRegistered',
  'MismatchSenderId',
  'InvalidPackageName',
]);

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
  const errors = [];
  for (const result of results || []) {
    if (!result || typeof result !== 'object') continue;
    summary.sent += Number(result.sent || 0);
    summary.failed += Number(result.failed || 0);
    summary.deactivated += Number(result.deactivated || 0);
    if (result.cleanupError) {
      errors.push(`${result.cleanupError}`);
    }
    if (Array.isArray(result.errors)) {
      errors.push(...result.errors.map((entry) => `${entry}`));
    }
    if (result.skipped && !summary.skipped) {
      summary.skipped = result.skipped;
    }
  }
  if (errors.length > 0) {
    summary.errors = errors;
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

async function sendFcm(tokens, payload) {
  const uniqueTokens = normalizeTokens(tokens);
  if (uniqueTokens.length === 0) {
    return { sent: 0, skipped: 'no_tokens' };
  }

  const key = process.env.FCM_SERVER_KEY;
  if (!key) {
    return { sent: 0, skipped: 'missing_fcm_server_key' };
  }

  const headers = {
    'Content-Type': 'application/json',
    Authorization: `key=${key}`,
  };

  let sent = 0;
  let failed = 0;
  const invalidTokens = [];
  const requestErrors = [];
  const chunkSize = 500;

  for (let i = 0; i < uniqueTokens.length; i += chunkSize) {
    const slice = uniqueTokens.slice(i, i + chunkSize);
    const body = {
      registration_ids: slice,
      priority: 'high',
      notification: payload.notification,
      data: payload.data || {},
    };

    try {
      const res = await fetch('https://fcm.googleapis.com/fcm/send', {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });
      const text = await res.text();
      let json = {};
      if (text) {
        try {
          json = JSON.parse(text);
        } catch (_) {
          json = { raw: text };
        }
      }

      if (!res.ok) {
        failed += slice.length;
        requestErrors.push(`HTTP ${res.status}: ${text || 'empty response'}`);
        continue;
      }

      if (Array.isArray(json.results)) {
        json.results.forEach((entry, index) => {
          const errorCode = `${entry?.error || ''}`.trim();
          if (entry?.message_id || entry?.registration_id) {
            sent += 1;
            return;
          }
          failed += 1;
          if (INVALID_FCM_ERRORS.has(errorCode)) {
            invalidTokens.push(slice[index]);
          }
        });
        continue;
      }

      const successCount = Number(json.success || 0);
      const failureCount = Number(json.failure || 0);
      sent += Number.isFinite(successCount) ? successCount : 0;
      failed += Number.isFinite(failureCount) ? failureCount : 0;
    } catch (error) {
      failed += slice.length;
      requestErrors.push(`${error}`);
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
};
