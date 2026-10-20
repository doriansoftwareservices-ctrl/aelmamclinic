'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs');
const {test,before}=require('node:test');
const {spawn}=require('node:child_process');
const url=new URL(process.env.ELMAM_OWNER_HASURA_URL);
assert.equal(url.hostname,'127.0.0.1');assert.ok(Number(url.port)>0);
const admin=process.env.ELMAM_OWNER_HASURA_ADMIN,key=process.env.ELMAM_OWNER_HASURA_JWT;
assert.ok(admin?.length>=32&&key?.length>=32);
const container=process.env.ELMAM_OWNER_HASURA_CONTAINER;
if(container)assert.match(container,/^elmam-owner-hasura-[0-9]+-[a-f0-9]+$/);
const uuid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
let serial=500;
function token(uid,{roles=['user','me'],secret=key}={}){
  const head=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
  const body=Buffer.from(JSON.stringify({sub:uid,exp:Math.floor(Date.now()/1000)+600,
    'https://hasura.io/jwt/claims':{'x-hasura-user-id':uid,'x-hasura-default-role':'user','x-hasura-allowed-roles':roles}})).toString('base64url');
  return `${head}.${body}.${crypto.createHmac('sha256',secret).update(`${head}.${body}`).digest('base64url')}`;
}
async function post(route,body,headers){
  assert.ok(['/v1/graphql','/v1/metadata','/v2/query'].includes(route));
  if(container){
    // Keep the whole fixture on its internal Docker network. This is actual
    // HTTP/JWT/Hasura, with concurrent child processes for parallel RPCs.
    const args=['exec','-i',container,'/usr/bin/curl','--silent','--show-error',
      '--max-time','10','--noproxy','*','--write-out','\n%{http_code}',
      '--request','POST','--header','content-type: application/json'];
    for(const[name,value]of Object.entries(headers))args.push('--header',`${name}: ${value}`);
    args.push('--data-binary','@-',new URL(route,url).toString());
    const output=await new Promise((resolve,reject)=>{
      const child=spawn('C:/Program Files/Docker/Docker/resources/bin/docker.exe',args,{windowsHide:true,stdio:['pipe','pipe','pipe']});
      let stdout='',stderr='';
      const timer=setTimeout(()=>{child.kill();reject(Error('Owned local HTTP timed out'));},20000);
      child.stdout.setEncoding('utf8').on('data',value=>{stdout+=value;});
      child.stderr.setEncoding('utf8').on('data',value=>{stderr+=value;});
      child.on('error',error=>{clearTimeout(timer);reject(error);});
      child.on('close',code=>{clearTimeout(timer);code===0?resolve(stdout):reject(Error(`Owned local HTTP failed ${code}: ${stderr}`));});
      child.stdin.end(JSON.stringify(body));
    });
    const split=output.lastIndexOf('\n');
    return {status:Number(output.slice(split+1)),body:JSON.parse(output.slice(0,split))};
  }
  const response=await fetch(new URL(route,url),{method:'POST',redirect:'error',
    headers:{'content-type':'application/json',...headers},body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
  return {status:response.status,body:await response.json()};
}
async function sql(statement,readOnly=false){
  const response=await post('/v2/query',{type:'run_sql',args:{source:'default',sql:statement,read_only:readOnly}}, {'x-hasura-admin-secret':admin});
  assert.equal(response.status,200,'private fixture SQL failed');return response.body;
}
async function scalar(statement){const result=await sql(statement,true);return result.result[1][0];}
const quote=s=>`'${String(s).replaceAll("'","''")}'`;
async function seed({role,disabled=false,membershipDisabled=false}={}){
  const uid=uuid(++serial);let account;
  await sql(`INSERT INTO auth.users(id,email,disabled) VALUES(${quote(uid)},'synthetic@example.invalid',${disabled});`);
  if(role){account=uuid(++serial);await sql(`INSERT INTO public.accounts(id,name) VALUES(${quote(account)},'Original paid clinic');
    INSERT INTO public.account_users VALUES(${quote(uid)},${quote(account)},${quote(role)},${membershipDisabled},now());
    INSERT INTO public.account_subscriptions(account_id,plan_code,status) VALUES(${quote(account)},'paid_fixture','active');`);}
  return {uid,account};
}
const values={name:'عيادة اختبار',city:'مدينة',street:'شارع',near:'بجوار',nameEn:"Synthetic clinic's name",cityEn:'City',streetEn:'Street',nearEn:'Near',phone:'000000000',phone2:'000000001'};
const mutation=`mutation CreateOwner($name:String!,$city:String!,$street:String!,$near:String!,$nameEn:String!,$cityEn:String!,$streetEn:String!,$nearEn:String!,$phone:String!,$phone2:String){
  self_create_account(args:{p_clinic_name:$name,p_city_ar:$city,p_street_ar:$street,p_near_ar:$near,p_clinic_name_en:$nameEn,p_city_en:$cityEn,p_street_en:$streetEn,p_near_en:$nearEn,p_phone:$phone,p_phone2:$phone2}){id}}`;
async function create(uid,{variables={},role='user',jwt,headers={},anonymous=false}={}){
  return post('/v1/graphql',{query:mutation,variables:{...values,...variables}},
    {...(!anonymous?{authorization:`Bearer ${jwt||token(uid)}`}:{}),'x-hasura-role':role,...headers});
}
function id(response){assert.equal(response.status,200);assert.equal(response.body.errors,undefined,response.body.errors?.map(e=>e.message).join(';'));return response.body.data.self_create_account[0].id;}
async function image(){return scalar(`SELECT jsonb_build_object(
  'accounts',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.accounts r),
  'users',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM auth.users r),
  'memberships',(SELECT jsonb_agg(to_jsonb(r) ORDER BY user_uid,account_id) FROM public.account_users r),
  'profiles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.profiles r),
  'subscriptions',(SELECT jsonb_agg(to_jsonb(r) ORDER BY account_id) FROM public.account_subscriptions r),
  'permissions',(SELECT jsonb_agg(to_jsonb(r) ORDER BY account_id) FROM public.account_feature_permissions r))::text;`);}
async function rejected(uid,options){const before=await image(),result=await create(uid,options);
  assert.ok(result.status>=400||result.body.errors?.length>0,'expected actual engine denial');assert.equal(await image(),before);}
before(async()=>{
  assert.equal(await scalar('SELECT value FROM public.elmam_owner_fixture_marker;'),'local_owner_onboarding_20261020');
  const metadata=JSON.parse(fs.readFileSync(process.env.ELMAM_OWNER_HASURA_METADATA,'utf8'));
  const result=await post('/v1/metadata',{type:'replace_metadata',args:{allow_inconsistent_metadata:false,metadata}},{'x-hasura-admin-secret':admin});
  assert.equal(result.status,200,result.body.error);
});
test('actual Hasura owner/result metadata is consistent',async()=>{
  const result=await post('/v1/metadata',{type:'get_inconsistent_metadata',args:{}},{'x-hasura-admin-secret':admin});
  assert.equal(result.status,200);assert.equal(result.body.is_consistent,true);
});
test('actual JWT user creates a complete bilingual clinic through the production RPC contract',async()=>{
  const {uid}=await seed(),account=id(await create(uid));
  assert.equal(await scalar(`SELECT name FROM public.accounts WHERE id=${quote(account)};`),values.name);
  assert.equal(await scalar(`SELECT clinic_name_en FROM public.accounts WHERE id=${quote(account)};`),values.nameEn);
  assert.equal(await scalar(`SELECT account_id::text FROM public.account_users WHERE user_uid=${quote(uid)};`),account);
});
for(const role of ['employee','doctor','member'])test(`actual engine linked ${role} cannot create a second owner clinic`,async()=>{await rejected((await seed({role})).uid);});
for(const role of ['owner','admin'])test(`actual engine ${role} retry preserves original paid plan/profile`,async()=>{
  const {uid,account}=await seed({role}),before=await image();assert.equal(id(await create(uid)),account);assert.equal(await image(),before);
});
test('actual engine disabled membership cannot create',async()=>{await rejected((await seed({role:'owner',membershipDisabled:true})).uid);});
test('actual engine retained JWT of a disabled Auth identity cannot create',async()=>{await rejected((await seed({disabled:true})).uid);});
for(const field of ['name','city','street','near','nameEn','cityEn','streetEn','nearEn','phone'])test(`actual engine empty required ${field} rolls back`,async()=>{
  await rejected((await seed()).uid,{variables:{[field]:' '}});
});
test('actual engine unauthenticated request does not write',async()=>{await rejected((await seed()).uid,{anonymous:true});});
test('actual engine invalid JWT signature does not write',async()=>{const {uid}=await seed();await rejected(uid,{jwt:token(uid,{secret:'wrong-owned-fixture-key'})});});
test('actual engine role header cannot elevate an ordinary signup JWT',async()=>{await rejected((await seed()).uid,{role:'superadmin'});});
test('actual engine caller header cannot replace the verified actor UID',async()=>{
  const own=await seed(),foreign=await seed(),account=id(await create(own.uid,{headers:{'x-hasura-user-id':foreign.uid}}));
  assert.equal(await scalar(`SELECT user_uid::text FROM public.account_users WHERE account_id=${quote(account)};`),own.uid);
  assert.equal(await scalar(`SELECT count(*)::text FROM public.account_users WHERE user_uid=${quote(foreign.uid)};`),'0');
});
test('actual engine me compatibility role retains the same identity guard',async()=>{
  const {uid}=await seed();assert.match(id(await create(uid,{role:'me'})),/^[0-9a-f-]{36}$/);
});
test('actual engine two concurrent RPCs create one clinic and return its original ID',async()=>{
  const {uid}=await seed(),responses=await Promise.all([create(uid),create(uid)]),ids=responses.map(id);
  assert.equal(new Set(ids).size,1);assert.equal(await scalar(`SELECT count(*)::text FROM public.account_users WHERE user_uid=${quote(uid)};`),'1');
  assert.equal(await scalar(`SELECT count(*)::text FROM public.account_subscriptions WHERE account_id=${quote(ids[0])};`),'1');
});
