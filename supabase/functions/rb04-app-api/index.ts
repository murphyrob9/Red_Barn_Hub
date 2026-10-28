/** RB-04 DEV: JWT-authenticated, server-enforced role-scoped app API.
 * Deploy as Edge Function rb04-app-api with JWT verification enabled.
 * Set SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY in Edge secrets.
 * Never expose service role or Clover secrets in Lovable/browser.
 * GET ?view=me | summary | weekly | reviews | my-tips
 * GET ?view=summary|weekly|reviews&start=YYYY-MM-DD&end=YYYY-MM-DD
 */
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const MERCHANT='44b7802c-9152-4a58-a81f-b12280f809e7';
const MANAGERS=new Set(['OWNER','ADMIN','MANAGER','SHIFT_LEAD']);
const ROLES=new Set(['OWNER','ADMIN','MANAGER','SHIFT_LEAD','BARTENDER']);
const ALLOWED_ORIGINS=(Deno.env.get('RB04_ALLOWED_ORIGINS')??'').split(',').map(x=>x.trim()).filter(Boolean);
function cors(req:Request):Record<string,string>{
  const origin=req.headers.get('Origin')??'';
  return origin && ALLOWED_ORIGINS.includes(origin) ? {
    'Access-Control-Allow-Origin':origin,
    'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info',
    'Access-Control-Allow-Methods':'GET,OPTIONS', 'Vary':'Origin'
  }: {'Vary':'Origin'};
}
function reply(req:Request,body:unknown,status=200){return new Response(JSON.stringify(body),{status,headers:{...cors(req),'Content-Type':'application/json','Cache-Control':'no-store'}});}
function dateOK(s:string|null){if(!s||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(s))return false;const d=new Date(`${s}T00:00:00Z`);return !Number.isNaN(d.getTime())&&d.toISOString().slice(0,10)===s;}
Deno.serve(async(req:Request)=>{
  const origin=req.headers.get('Origin');
  if(origin && !ALLOWED_ORIGINS.includes(origin))return reply(req,{error:'Origin not permitted'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors(req)});
  if(req.method!=='GET')return reply(req,{error:'GET required'},405);
  const url=Deno.env.get('SUPABASE_URL'),pub=Deno.env.get('SUPABASE_ANON_KEY')??Deno.env.get('SUPABASE_PUBLISHABLE_KEY');
  const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!pub||!service)return reply(req,{error:'Server not configured'},503);
  const authorization=req.headers.get('Authorization')??'';
  if(!/^Bearer\s+\S+$/i.test(authorization))return reply(req,{error:'Sign in required'},401);
  const token=authorization.replace(/^Bearer\s+/i,'');
  try{
    const auth=createClient(url,pub,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:{user},error:authError}=await auth.auth.getUser(token);
    if(authError||!user)return reply(req,{error:'Invalid or expired session'},401);
    const db=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:membership,error:memberError}=await db.schema('rb04').from('dashboard_memberships')
      .select('app_role,active,accountability_employee_id').eq('merchant_id',MERCHANT).eq('user_id',user.id).maybeSingle();
    if(memberError)throw memberError;
    if(!membership?.active||!ROLES.has(membership.app_role))return reply(req,{error:'Account is not authorized for this merchant'},403);
    const role=membership.app_role as string;
    const p=new URL(req.url).searchParams,view=p.get('view')??'me';
    if(view==='me')return reply(req,{userId:user.id,email:user.email,role,merchantId:MERCHANT,
      employeeLinked:!!membership.accountability_employee_id,managerAccess:MANAGERS.has(role)});
    const start=p.get('start'),end=p.get('end');
    if(!dateOK(start)||!dateOK(end)||start!>end!||Date.parse(end!)-Date.parse(start!)>93*86400000)
      return reply(req,{error:'Valid start/end dates required (maximum 93 days)'},400);
    if(view==='my-tips'){
      // Fail closed: employees must have an explicit employee identity mapping.
      if(!membership.accountability_employee_id)return reply(req,{error:'Employee account not linked'},403);
      const {data:employee,error:empError}=await db.schema('rb04').from('accountability_employees')
        .select('clover_employee_id').eq('merchant_id',MERCHANT).eq('id',membership.accountability_employee_id).maybeSingle();
      if(empError)throw empError;
      if(!employee?.clover_employee_id)return reply(req,{error:'Clover employee identity not mapped'},403);
      const {data,error}=await db.schema('rb04').from('accountability_events')
        .select('business_date,observed_at,amount_cents,source_payment_id,source_event_key')
        .eq('merchant_id',MERCHANT).eq('source_employee_id',employee.clover_employee_id)
        .eq('event_type','TIP').gte('business_date',start!).lte('business_date',end!)
        .order('observed_at',{ascending:false}).limit(250);
      if(error)throw error;
      return reply(req,{view,role,rows:data??[],coverage:'Posted ledger only; not proof of complete Clover tips'});
    }
    if(!MANAGERS.has(role))return reply(req,{error:'Management authorization required'},403);
    if(view==='summary'){
      const {data,error}=await db.schema('rb04').from('accountability_dashboard_daily').select('*')
        .eq('merchant_id',MERCHANT).gte('business_date',start!).lte('business_date',end!).limit(100);
      if(error)throw error;
      return reply(req,{view,role,rows:data??[],coverage:'Posted ledger only; not a verified complete Clover reconciliation'});
    }
    if(view==='weekly'){
      const {data,error}=await db.schema('rb04').from('accountability_dashboard_employee_weekly').select('*')
        .eq('merchant_id',MERCHANT).gte('week_start_monday',start!).lte('week_start_monday',end!).limit(500);
      if(error)throw error;
      return reply(req,{view,role,rows:data??[],coverage:'Posted ledger only; not a verified complete Clover reconciliation'});
    }
    if(view==='reviews'){
      const {data,error}=await db.schema('rb04').from('accountability_dashboard_review_queue').select('*')
        .eq('merchant_id',MERCHANT).gte('business_date',start!).lte('business_date',end!).limit(500);
      if(error)throw error;
      return reply(req,{view,role,rows:data??[],coverage:'Review candidates from posted ledger; read-only'});
    }
    return reply(req,{error:'Unknown view'},400);
  }catch(e){console.error('RB04 app API failed',e);return reply(req,{error:'Dashboard service unavailable'},503);}
});
