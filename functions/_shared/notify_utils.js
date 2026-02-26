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

async function sendFcm(tokens, payload) {
  const key = process.env.FCM_SERVER_KEY;
  if (!key || !tokens || tokens.length === 0) return { sent: 0 };

  const headers = {
    'Content-Type': 'application/json',
    Authorization: `key=${key}`,
  };

  let sent = 0;
  const chunkSize = 500;
  for (let i = 0; i < tokens.length; i += chunkSize) {
    const slice = tokens.slice(i, i + chunkSize);
    const body = {
      registration_ids: slice,
      priority: 'high',
      notification: payload.notification,
      data: payload.data || {},
    };
    const res = await fetch('https://fcm.googleapis.com/fcm/send', {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });
    if (res.ok) sent += slice.length;
  }
  return { sent };
}

module.exports = {
  readBody,
  gqlRequest,
  sendFcm,
};
