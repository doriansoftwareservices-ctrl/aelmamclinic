'use strict';
const crypto = require('node:crypto');
const {createNotificationRepositoryV2} = require('./notification_repository_v2');
const {createNotificationAuthorityQuery,resolveNotificationAuthority} = require('./notification_authority_v2');
const {dispatchNotificationBatchV2} = require('./notification_dispatch_v2');
const {createNotificationFcmV2,resolveNotificationCredentials} = require('./notification_fcm_v2');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class NotificationHttpError extends Error {
  constructor(status,code) {super(code);this.status=status;this.code=code;}
}
const fail = (status=503,code='notification_temporarily_unavailable') => {throw new NotificationHttpError(status,code);};

function notificationConfig(env=process.env) {
  const secret = env.GRAPHQL_ADMIN_SECRET || env.NHOST_ADMIN_SECRET || env.HASURA_GRAPHQL_ADMIN_SECRET;
  const raw = env.NHOST_GRAPHQL_URL || env.HASURA_GRAPHQL_URL ||
    (env.NHOST_SUBDOMAIN && env.NHOST_REGION ? 'https://'+env.NHOST_SUBDOMAIN+'.graphql.'+env.NHOST_REGION+'.nhost.run/v1' : '');
  try {
    // Nhost's public graphql host serves /v1, whereas the Hasura host serves
    // /v1/graphql. Repositories use the latter contract. Rewrite only the
    // service label on an actual Nhost hostname, never a custom API hostname.
    const endpoint = new URL(raw);
    if (endpoint.hostname.endsWith('.nhost.run')) {
      endpoint.hostname = endpoint.hostname.replace('.graphql.','.hasura.');
    }
    const graphql = endpoint.toString().replace(/\/+$/,'')
      .replace(/\/v1\/graphql$/,'').replace(/\/v1$/,'')+'/v1/graphql';
    const auth = (env.NHOST_AUTH_URL || raw.replace(/\.(graphql|hasura)\./,'.auth.'))
      .replace(/\/+$/,'').replace(/\/v1\/graphql$/,'').replace(/\/v1$/,'')+'/v1/user';
    if (!secret || !raw || endpoint.protocol !== 'https:' || new URL(auth).protocol !== 'https:') fail();
    return {graphql,auth,secret};
  } catch (_) {fail();}
}

async function notificationRequest(url,options,fetchImpl=globalThis.fetch,timeoutMs=4000) {
  const controller = new AbortController();let timer;
  try {
    const operation = (async () => {
      const response = await fetchImpl(url,{...options,signal:controller.signal});
      const body = await response.json();
      return {status:response.status,body};
    })();
    return await Promise.race([operation,new Promise((_,reject) => {
      timer=setTimeout(() => {controller.abort();reject(new NotificationHttpError(503,'notification_temporarily_unavailable'));},timeoutMs);
    })]);
  } catch (_) {fail();}
  finally {clearTimeout(timer);}
}

function notificationAdmin(config,fetchImpl) {
  return async (query,variables={}) => {
    const result = await notificationRequest(config.graphql,{method:'POST',
      headers:{'Content-Type':'application/json','x-hasura-admin-secret':config.secret},
      body:JSON.stringify({query,variables})},fetchImpl);
    if (Array.isArray(result.body?.errors)) {
      const known={notification_registration_invalid:400,notification_registration_denied:403,
        notification_installation_secret_mismatch:403,notification_registration_stale:409,
        notification_registration_identity_mismatch:409};
      for(const error of result.body.errors) {
        // Hasura may omit internal details and prefix PostgreSQL check errors.
        // Match only exact reviewed codes, never arbitrary upstream SQL text.
        for(const raw of [error.extensions?.internal?.error?.message,error.message]) {
          const message=typeof raw==='string'?raw.replace(/^Check constraint violation\. /,''):null;
          if(Object.hasOwn(known,message))fail(known[message],message);
        }
      }
    }
    if (result.status!==200 || result.body?.errors || !result.body?.data ||
      typeof result.body.data!=='object' || Array.isArray(result.body.data)) fail();
    return result.body.data;
  };
}

async function notificationActor(req,config,fetchImpl) {
  const header=req.headers?.authorization || req.headers?.Authorization || '';
  if (typeof header!=='string' || header.length>16384 || !/^Bearer [^\s]+$/i.test(header)) fail(401,'invalid_session');
  const result=await notificationRequest(config.auth,{method:'GET',headers:{Authorization:header}},fetchImpl);
  if ([401,403].includes(result.status)) fail(401,'invalid_session');
  if (result.status!==200) fail();
  const user=result.body?.user || result.body;
  if (!UUID.test(user?.id || '') || user.disabled===true) fail(401,'invalid_session');
  return user.id;
}

async function notificationBody(req) {
  const parse = value => {
    try {
      const raw=typeof value==='string' || Buffer.isBuffer(value) ? value.toString() : JSON.stringify(value);
      if (Buffer.byteLength(raw)>8192) fail(413,'request_too_large');
      const body=JSON.parse(raw);
      if (!body || typeof body!=='object' || Array.isArray(body)) fail(400,'invalid_request');
      return body;
    } catch(error) {if (error instanceof NotificationHttpError) throw error;fail(400,'invalid_request');}
  };
  if (req.body!=null) return parse(req.body);
  if (typeof req.on!=='function') fail(400,'invalid_request');
  return new Promise((resolve,reject) => {
    const chunks=[];let length=0;let done=false;
    const finish=(error,value) => {if(done)return;done=true;clearTimeout(timer);error?reject(error):resolve(value);};
    const timer=setTimeout(() => finish(new NotificationHttpError(408,'request_timeout')),4000);
    req.on('data',chunk => {if(done)return;length+=Buffer.byteLength(chunk);
      if(length>8192)finish(new NotificationHttpError(413,'request_too_large'));else chunks.push(Buffer.from(chunk));});
    req.on('error',() => finish(new NotificationHttpError(400,'invalid_request')));
    req.on('end',() => {if(done)return;try{finish(null,parse(Buffer.concat(chunks)));}catch(error){finish(error);}});
  });
}

function notificationReply(res,error) {
  const status=error instanceof NotificationHttpError ? error.status : 503;
  res.status(status).json({ok:false,error:status===503?'notification_temporarily_unavailable':error.code});
}

function createNotificationDispatchHandler({env=process.env,fetchImpl=globalThis.fetch,provider=null}={}) {
  let transport;
  return async (req,res) => {
    if(req.method!=='POST'){res.status(405).json({ok:false,error:'method_not_allowed'});return;}
    try {
      const expected=env.HASURA_EVENT_SECRET || env.NHOST_WEBHOOK_SECRET || env.WEBHOOK_SECRET;
      if(typeof expected!=='string' || !expected) fail(503,'notification_temporarily_unavailable');
      const supplied=req.headers?.['x-hasura-event-secret'] || req.headers?.['x-webhook-secret'];
      if(typeof supplied!=='string') fail(401,'invalid_dispatch_secret');
      const a=Buffer.from(expected),b=Buffer.from(supplied);
      if(a.length!==b.length || !crypto.timingSafeEqual(a,b)) fail(403,'invalid_dispatch_secret');
      const config=notificationConfig(env);
      const baseRepository=createNotificationRepositoryV2({url:config.graphql,adminSecret:config.secret,fetchImpl});
      const repository={...baseRepository,enabled:async args => {
        const active=await baseRepository.enabled(args);
        // A configuration outage must not consume the destination retry budget.
        if(active && !provider) transport??=createNotificationFcmV2({credentials:resolveNotificationCredentials(env),fetchImpl});
        return active;
      }};
      const query=createNotificationAuthorityQuery({url:config.graphql,adminSecret:config.secret,fetchImpl});
      const result=await dispatchNotificationBatchV2({repository,
        resolveAuthority:target => resolveNotificationAuthority(target,{query}),
        send:async args => {
          if(provider)return provider(args);
          transport??=createNotificationFcmV2({credentials:resolveNotificationCredentials(env),fetchImpl});
          return transport(args);
        }});
      res.status(200).json({ok:true,...result});
    }catch(error){notificationReply(res,error);}
  };
}

module.exports={NotificationHttpError,notificationConfig,notificationRequest,notificationAdmin,
  notificationActor,notificationBody,notificationReply,createNotificationDispatchHandler};
