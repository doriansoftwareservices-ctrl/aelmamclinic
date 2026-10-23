'use strict';

// HTTP-v1 contracts: https://firebase.google.com/docs/cloud-messaging/send/v1-api
// Only typed UNREGISTERED retires a registration; INVALID_ARGUMENT may instead
// describe our payload and must not disable a valid device.
const crypto = require('node:crypto');
const {performance} = require('node:perf_hooks');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const retryable = () => ({outcome: 'retryable'});

function resolveNotificationCredentials(env = process.env) {
  for (const key of ['FIREBASE_SERVICE_ACCOUNT_JSON','GOOGLE_SERVICE_ACCOUNT_JSON','GCP_SERVICE_ACCOUNT_JSON']) {
    if (!env[key]?.trim()) continue;
    try {
      const value = JSON.parse(env[key]);
      return {clientEmail: value.client_email, privateKey: value.private_key, projectId: value.project_id};
    } catch (_) {return null;}
  }
  return {clientEmail: env.FIREBASE_CLIENT_EMAIL || env.GOOGLE_CLIENT_EMAIL,
    privateKey: env.FIREBASE_PRIVATE_KEY || env.GOOGLE_PRIVATE_KEY,
    projectId: env.FIREBASE_PROJECT_ID || env.GOOGLE_CLOUD_PROJECT || env.GCLOUD_PROJECT};
}

function validData(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return false;
  const required = ['notification_protocol','event_id','target_id','ack_nonce','recipient_uid',
    'installation_id','account_id','kind','source_id'];
  if (!required.every(key => Object.hasOwn(data,key)) || Object.keys(data).some(
    key => ![...required,'conversation_id'].includes(key)) || Object.values(data).some(value => typeof value !== 'string')) return false;
  return data.notification_protocol === '2' && /^nev2_[0-9a-f]{64}$/.test(data.event_id) &&
    ['target_id','ack_nonce','recipient_uid','installation_id','source_id'].every(key => UUID.test(data[key])) &&
    (data.account_id === '' || UUID.test(data.account_id)) &&
    ['new_patient','chat_message','plan_request','seat_request'].includes(data.kind) &&
    (data.kind === 'chat_message' ? UUID.test(data.conversation_id) : !Object.hasOwn(data,'conversation_id'));
}

function createNotificationFcmV2({credentials = resolveNotificationCredentials(), fetchImpl = globalThis.fetch,
  timeoutMs = 7000, now = Date.now, monotonicNow = () => performance.now()} = {}) {
  let key;
  try {
    if (!credentials || typeof credentials.clientEmail !== 'string' ||
      !/^[^\s@]+@[^\s@]+$/.test(credentials.clientEmail) ||
      typeof credentials.projectId !== 'string' || !/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(credentials.projectId) ||
      typeof credentials.privateKey !== 'string' || typeof fetchImpl !== 'function' ||
      !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 7000) throw new Error();
    key = crypto.createPrivateKey(credentials.privateKey.replace(/\\n/g,'\n'));
    if (key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 2048) throw new Error();
  } catch (_) {throw new Error('notification_provider_not_configured');}
  const projectId = credentials.projectId;
  let cached = null;
  const json = async response => {
    const text = await response.text();
    if (text.length > 65536) throw new Error();
    return JSON.parse(text);
  };
  return async ({token,data,signal}) => {
    if (typeof token !== 'string' || !token.trim() || token.length > 4096 || !validData(data)) return retryable();
    const controller = new AbortController();let timer;let rejectAbort;
    const abort = () => {controller.abort();rejectAbort?.(new Error('notification_provider_unavailable'));};
    try {
      if (signal?.aborted) return retryable();
      signal?.addEventListener('abort',abort,{once:true});
      const deadline = new Promise((_,reject) => {rejectAbort=reject;timer=setTimeout(abort,timeoutMs);});
      const operation = async () => {
        let accessToken;
        if (cached && monotonicNow() < cached.until) accessToken = cached.token;
        else {
          const issued = Math.floor(now()/1000);
          const header = Buffer.from(JSON.stringify({alg:'RS256',typ:'JWT'})).toString('base64url');
          const claim = Buffer.from(JSON.stringify({iss:credentials.clientEmail,
            scope:'https://www.googleapis.com/auth/firebase.messaging',aud:'https://oauth2.googleapis.com/token',
            iat:issued,exp:issued+3600})).toString('base64url');
          const unsigned = header+'.'+claim;
          const assertion = unsigned+'.'+crypto.sign('RSA-SHA256',Buffer.from(unsigned),key).toString('base64url');
          const response = await fetchImpl('https://oauth2.googleapis.com/token',{method:'POST',signal:controller.signal,
            headers:{'Content-Type':'application/x-www-form-urlencoded'},
            body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}).toString()});
          const value = await json(response);
          if (response.status !== 200 || typeof value.access_token !== 'string' || !value.access_token.trim() ||
            !Number.isFinite(value.expires_in) || value.expires_in <= 0) return retryable();
          accessToken = value.access_token;
          cached = {token:accessToken,until:monotonicNow()+Math.max(0,Math.min(value.expires_in,3600)-60)*1000};
        }
        if (controller.signal.aborted) return retryable();
        const response = await fetchImpl('https://fcm.googleapis.com/v1/projects/'+projectId+'/messages:send',{
          method:'POST',signal:controller.signal,headers:{'Content-Type':'application/json',Authorization:'Bearer '+accessToken},
          body:JSON.stringify({message:{token,data,android:{priority:'HIGH',ttl:'3600s'}}})});
        const value = await json(response);
        if (response.status === 401) cached = null;
        if (response.status === 200 && typeof value.name === 'string' && value.name.length<=512 &&
          new RegExp('^projects/'+projectId+'/messages/[A-Za-z0-9_.:%+-]+$').test(value.name)) {
          return {outcome:'accepted',providerMessageId:value.name};
        }
        const errors = value?.error?.details;
        if (response.status === 404 && Array.isArray(errors) && errors.some(error =>
          error?.['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError' && error.errorCode === 'UNREGISTERED')) {
          return {outcome:'unregistered'};
        }
        return retryable();
      };
      return await Promise.race([operation(),deadline]);
    } catch (_) {return retryable();}
    finally {clearTimeout(timer);signal?.removeEventListener('abort',abort);}
  };
}

module.exports = {resolveNotificationCredentials,createNotificationFcmV2};
