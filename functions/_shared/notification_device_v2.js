'use strict';
const crypto=require('node:crypto');
const {notificationConfig,notificationAdmin,notificationActor,notificationBody,notificationReply,NotificationHttpError}=require('./notification_runtime_v2');
const {createNotificationAuthorityQuery,resolveNotificationAuthority}=require('./notification_authority_v2');
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fail=(status,code)=>{throw new NotificationHttpError(status,code);};
const hash=value=>crypto.createHash('sha256').update(value).digest('hex');
function proof(body) {
  if(!UUID.test(body.installation_id || '') || typeof body.installation_secret!=='string' ||
    !/^[A-Za-z0-9_-]{43}$/.test(body.installation_secret) ||
    Buffer.from(body.installation_secret,'base64url').length!==32 ||
    Buffer.from(body.installation_secret,'base64url').toString('base64url')!==body.installation_secret) fail(400,'invalid_request');
  return hash(body.installation_secret);
}
const documents=Object.freeze({
  register:`mutation RegisterNotificationInstallation($uid:uuid!,$install:uuid!,$proof:String!,$revision:bigint!,$account:uuid,$token:String,$locale:String!,$request:String!,$deactivate:Boolean!) {
    register_notification_installation_v2(args:{p_actor:$uid,p_installation:$install,p_secret_hash:$proof,p_revision:$revision,
      p_account:$account,p_token:$token,p_locale:$locale,p_request_hash:$request,p_deactivate:$deactivate}) {
      installation_id client_revision bound_user_uid is_active
    }
  }`,
  binding:`query NotificationInstallationProof($id:uuid!) {
    notification_installations_v2_by_pk(installation_id:$id) {secret_hash bound_user_uid is_active}
  }`,
  target:`query NotificationDestinationProof($id:uuid!) {
    notification_delivery_targets_v2_by_pk(id:$id) {
      id event_id user_uid token_id installation_id ack_nonce status
      delivery_event {event_id event_type source_id account_id}
    }
  }`,
  ack:`mutation AcknowledgeNotificationDestination($id:uuid!,$uid:uuid!,$nonce:uuid!) {
    acknowledge_notification_target_v2(args:{p_id:$id,p_actor:$uid,p_nonce:$nonce}) {id status acknowledged_at}
  }`,
});
function createNotificationRegistrationHandler({env=process.env,fetchImpl=globalThis.fetch}={}) {
  return async(req,res)=>{
    if(req.method!=='POST'){res.status(405).json({ok:false,error:'method_not_allowed'});return;}
    try {
      const config=notificationConfig(env),uid=await notificationActor(req,config,fetchImpl);
      const body=await notificationBody(req);
      const allowed=['installation_id','installation_secret','revision','account_id','token','locale','deactivate'];
      if(Object.keys(body).some(key=>!allowed.includes(key)))fail(400,'invalid_request');
      const secretHash=proof(body);
      const revision=String(body.revision);
      if(!/^[1-9][0-9]{0,15}$/.test(revision) || !Number.isSafeInteger(Number(revision)) ||
        typeof body.revision!=='number' && typeof body.revision!=='string')fail(400,'invalid_request');
      const account=body.account_id??null,deactivate=body.deactivate??false,locale=body.locale??'ar';
      if(account!==null && !UUID.test(account) || typeof deactivate!=='boolean' || !['ar','en'].includes(locale) ||
        !deactivate && (typeof body.token!=='string' || !body.token.trim() || Buffer.byteLength(body.token)>4096))fail(400,'invalid_request');
      const token=deactivate?null:body.token;
      const requestHash=hash(JSON.stringify({uid,install:body.installation_id,secretHash,revision,account,token,locale,deactivate}));
      const result=await notificationAdmin(config,fetchImpl)(documents.register,{uid,install:body.installation_id,
        proof:secretHash,revision,account,token,locale,request:requestHash,deactivate});
      const rows=result.register_notification_installation_v2;
      if(!Array.isArray(rows) || rows.length!==1 || rows[0].installation_id!==body.installation_id ||
        rows[0].bound_user_uid!==uid || String(rows[0].client_revision)!==revision || rows[0].is_active!==!deactivate) {
        fail(503,'notification_temporarily_unavailable');
      }
      res.status(200).json({ok:true,notification_protocol:2,revision,active:!deactivate});
    }catch(error){notificationReply(res,error);}
  };
}
function createNotificationReceiptHandler({env=process.env,fetchImpl=globalThis.fetch}={}) {
  return async(req,res)=>{
    if(req.method!=='POST'){res.status(405).json({ok:false,error:'method_not_allowed'});return;}
    try {
      const config=notificationConfig(env);
      const body=await notificationBody(req);const secretHash=proof(body);
      if(Object.keys(body).some(key=>!['installation_id','installation_secret','target_id','ack_nonce','action'].includes(key)) ||
        !UUID.test(body.target_id || '') || !UUID.test(body.ack_nonce || '') || !['ack','validate'].includes(body.action??'ack')) fail(400,'invalid_request');
      const admin=notificationAdmin(config,fetchImpl);
      const identity=await admin(documents.binding,{id:body.installation_id});
      const binding=identity.notification_installations_v2_by_pk;
      // The installation secret is a narrow device capability. Registration
      // requires verified Auth; this capability grants only validation/ACK of
      // a known target+nonce, never access to clinical records. Background
      // receipt therefore does not rotate a shared Auth refresh token.
      if(!binding || !UUID.test(binding.bound_user_uid || '') || binding.is_active!==true ||
        typeof binding.secret_hash!=='string' || binding.secret_hash.length!==64 ||
        !crypto.timingSafeEqual(Buffer.from(binding.secret_hash),Buffer.from(secretHash))) fail(403,'invalid_device_binding');
      const uid=binding.bound_user_uid;
      if(req.headers?.authorization || req.headers?.Authorization) {
        const actor=await notificationActor(req,config,fetchImpl);
        if(actor!==uid)fail(403,'invalid_device_binding');
      }
      const data=await admin(documents.target,{id:body.target_id});
      const target=data.notification_delivery_targets_v2_by_pk;
      if(!target || target.user_uid!==uid || target.installation_id!==body.installation_id ||
        target.ack_nonce!==body.ack_nonce || target.status==='cancelled')fail(404,'notification_unavailable');
      const query=createNotificationAuthorityQuery({url:config.graphql,adminSecret:config.secret,fetchImpl});
      const authority=await resolveNotificationAuthority(target,{query});
      if(!authority.allowed)fail(403,'notification_no_longer_authorized');
      if(body.action==='validate') {
        res.status(200).json({ok:true,authorized:true,kind:authority.kind,account_id:authority.accountId,
          source_id:authority.sourceId,...(authority.conversationId?{conversation_id:authority.conversationId}:{})});return;
      }
      const result=await admin(documents.ack,{id:target.id,uid,nonce:body.ack_nonce});
      const rows=result.acknowledge_notification_target_v2;
      if(!Array.isArray(rows) || rows.length!==1 || rows[0].id!==target.id || rows[0].status!=='acknowledged' ||
        typeof rows[0].acknowledged_at!=='string' || !Number.isFinite(Date.parse(rows[0].acknowledged_at)) ||
        !/(Z|[+-][0-9]{2}:[0-9]{2})$/.test(rows[0].acknowledged_at))fail(503,'notification_temporarily_unavailable');
      res.status(200).json({ok:true,acknowledged:true,acknowledged_at:rows[0].acknowledged_at});
    }catch(error){notificationReply(res,error);}
  };
}
module.exports={documents,createNotificationRegistrationHandler,createNotificationReceiptHandler};
