import {createClient} from "npm:@supabase/supabase-js@2";
const URL=Deno.env.get("SUPABASE_URL")??"",ANON=Deno.env.get("SUPABASE_ANON_KEY")??"",SERVICE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const SITE="https://wariwo23.github.io";
const cors={"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
function out(body:Record<string,unknown>,status=200,origin:string|null=null){return new Response(JSON.stringify(body),{status,headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null","Content-Type":"application/json"}});}
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get("Origin");
 if(req.method==="OPTIONS")return new Response("ok",{headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null"}});
 if(req.method!=="POST")return out({error:"POST requests only."},405,origin);
 if(origin&&origin!==SITE)return out({error:"Origin not allowed."},403,origin);
 try{
  const authorization=req.headers.get("Authorization")||"";
  if(!authorization.startsWith("Bearer "))return out({error:"Customer sign-in required."},401,origin);
  const jwt=authorization.slice(7);
  const auth=createClient(URL,ANON,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error}=await auth.auth.getUser(jwt);
  if(error||!user)return out({error:"Your customer session is invalid or expired."},401,origin);
  const body=await req.json().catch(()=>null);
  if(!body||typeof body!=="object")return out({error:"Invalid decision request."},400,origin);
  const quoteId=typeof body.quotation_id==="string"?body.quotation_id:"";
  const decision=String(body.decision||"");
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(quoteId)||!["accept","decline"].includes(decision))
   return out({error:"Invalid quotation decision."},400,origin);
  const db=createClient(URL,SERVICE,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:result,error:decisionError}=await db.rpc("frosttech_decide_direct_quotation",{
   p_quote_id:quoteId,p_actor:user.id,p_decision:decision,
   p_terms_accepted:body.terms_accepted===true,
   p_delivery_address:typeof body.delivery_address==="string"?body.delivery_address.trim():null,
   p_customer_notes:typeof body.customer_notes==="string"?body.customer_notes.trim():null,
   p_decline_reason:typeof body.decline_reason==="string"?body.decline_reason.trim():null
  });
  if(decisionError){console.error("Direct quotation decision rejected:",decisionError);return out({error:decisionError.message||"The quotation decision could not be recorded."},409,origin);}
  return out(result||{success:true},200,origin);
 }catch(e){console.error("Direct quotation decision error:",e);return out({error:"Unable to process your quotation decision."},500,origin);}
});