import { createClient } from "npm:@supabase/supabase-js@2";
const URL=Deno.env.get("SUPABASE_URL")??"";
const ANON=Deno.env.get("SUPABASE_ANON_KEY")??"";
const SERVICE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const SITE="https://wariwo23.github.io";
const cors={"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
function out(body:Record<string,unknown>,status=200,origin:string|null=null){
 return new Response(JSON.stringify(body),{status,headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null","Content-Type":"application/json"}});
}
async function hash(value:string):Promise<string>{
 const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));
 return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,"0")).join("");
}
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get("Origin");
 if(req.method==="OPTIONS")return new Response("ok",{headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null"}});
 if(req.method!=="POST")return out({error:"POST requests only."},405,origin);
 if(origin&&origin!==SITE)return out({error:"Origin not allowed."},403,origin);
 try{
  const authorization=req.headers.get("Authorization")||"";
  if(!authorization.startsWith("Bearer "))return out({error:"Please sign in to your FrostTech customer account."},401,origin);
  const token=authorization.slice(7);
  const auth=createClient(URL,ANON,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error}=await auth.auth.getUser(token);
  if(error||!user||!user.email)return out({error:"Your customer session is invalid or expired."},401,origin);
  const body=await req.json().catch(()=>null);
  const rawToken=typeof body?.token==="string"?body.token:"";
  if(rawToken.length<32||rawToken.length>128||!/^[A-Za-z0-9_-]+$/.test(rawToken))
    return out({error:"The quotation invitation link is invalid."},400,origin);
  const db=createClient(URL,SERVICE,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:quote,error:claimError}=await db.rpc("frosttech_claim_direct_quote_invitation",{
    p_token_hash:await hash(rawToken),p_actor:user.id
  });
  if(claimError||!quote){
    console.error("Direct quotation invitation claim failed:",claimError);
    return out({error:claimError?.message||"This invitation could not be verified. Check that you are signed in with the invited email address."},403,origin);
  }
  return out({success:true,quotation:quote},200,origin);
 }catch(e){
  console.error("Direct customer quotation access error:",e);
  return out({error:"Unable to load this quotation at the moment."},500,origin);
 }
});