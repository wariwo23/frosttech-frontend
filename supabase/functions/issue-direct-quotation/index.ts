import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RESEND = Deno.env.get("RESEND_API_KEY") ?? "";
const EMAIL_FROM = Deno.env.get("EMAIL_FROM") ?? "";
const ORIGIN = "https://wariwo23.github.io";
const SITE = "https://wariwo23.github.io/frosttech-frontend";

const headers = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function response(body: Record<string, unknown>, status = 200, origin: string | null = null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...headers,
      "Access-Control-Allow-Origin": !origin || origin === ORIGIN ? (origin || ORIGIN) : "null",
      "Content-Type": "application/json",
    },
  });
}
function escapeHtml(value: unknown): string {
  return String(value ?? "").replaceAll("&","&amp;").replaceAll("<","&lt;")
    .replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#39;");
}
function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,"");
}
async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map(x=>x.toString(16).padStart(2,"0")).join("");
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok",{headers:{
    ...headers,"Access-Control-Allow-Origin":!origin||origin===ORIGIN?(origin||ORIGIN):"null"
  }});
  if (req.method !== "POST") return response({error:"POST requests only."},405,origin);
  if (origin && origin !== ORIGIN) return response({error:"Origin not allowed."},403,origin);
  if (!URL || !ANON || !SERVICE) return response({error:"Quotation service is not configured."},500,origin);

  try {
    const authorization=req.headers.get("Authorization")||"";
    if(!authorization.startsWith("Bearer ")) return response({error:"Administrator sign-in required."},401,origin);
    const token=authorization.slice(7);
    const auth=createClient(URL,ANON,{global:{headers:{Authorization:"Bearer "+token}},auth:{persistSession:false,autoRefreshToken:false}});
    const {data:{user},error:authError}=await auth.auth.getUser(token);
    if(authError||!user) return response({error:"Your session is invalid or expired."},401,origin);
    const {data:role,error:roleError}=await auth.rpc("admin_get_my_role");
    if(roleError||!["super_admin","operations_admin"].includes(String(role))) {
      return response({error:"Super Administrator or Operations Administrator access is required."},403,origin);
    }
    const body=await req.json().catch(()=>null);
    const quoteId=typeof body?.quotation_id==="string"?body.quotation_id:"";
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(quoteId))
      return response({error:"A valid quotation ID is required."},400,origin);

    const db=createClient(URL,SERVICE,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:quote,error:quoteError}=await db.from("frosttech_direct_quotations")
      .select("id,quotation_number,customer_name,customer_email,total_amount,validity_expires_at,status,created_by")
      .eq("id",quoteId).eq("created_by",user.id).maybeSingle();
    if(quoteError||!quote) return response({error:"Your quotation draft could not be found."},404,origin);
    if(quote.status!=="draft") return response({error:"Only a saved draft can be issued."},409,origin);
    if(quote.validity_expires_at && new Date(quote.validity_expires_at).getTime()<=Date.now())
      return response({error:"The quotation validity date has passed."},400,origin);

    const rawInvite=randomToken();
    const hash=await sha256(rawInvite);
    const expires=new Date(Date.now()+7*24*60*60*1000).toISOString();
    const {data:issued,error:issueError}=await db.rpc("frosttech_issue_direct_quotation",{
      p_quote_id:quoteId,p_actor:user.id,p_invite_token_hash:hash,p_invite_expires_at:expires
    });
    if(issueError||!issued) {
      console.error("Direct quotation issue failed:",issueError);
      return response({error:"The quotation could not be issued. No invitation was sent."},409,origin);
    }

    const invitationUrl=SITE+"/direct-quotation.html?token="+encodeURIComponent(rawInvite);
    let emailSent=false;
    let emailMessage="Email delivery is not configured; copy the secure invitation link and send it to the customer.";
    if(RESEND && EMAIL_FROM) {
      const html=`<div style="font-family:Arial,sans-serif;color:#172333;max-width:620px;margin:auto;line-height:1.6">
        <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
        <p>Hello ${escapeHtml(quote.customer_name)},</p>
        <p>FrostTech has prepared a quotation for you.</p>
        <p><strong>Quotation reference:</strong> ${escapeHtml(quote.quotation_number)}</p>
        <p><strong>Quotation total:</strong> ₦${Number(quote.total_amount).toLocaleString("en-NG",{minimumFractionDigits:2,maximumFractionDigits:2})}</p>
        <p>Please sign in or create your FrostTech customer account using this email address, then open the secure link below to view the quotation.</p>
        <p><a href="${invitationUrl}" style="display:inline-block;background:#0879c9;color:#fff;padding:12px 18px;border-radius:6px;text-decoration:none">Review my quotation</a></p>
        <p>This invitation expires in 7 days and can only be claimed by an account using the email address this message was sent to.</p>
        <p>If you were not expecting this quotation, you can ignore this email.</p>
      </div>`;
      try {
        const sent=await fetch("https://api.resend.com/emails",{
          method:"POST",
          headers:{"Authorization":"Bearer "+RESEND,"Content-Type":"application/json","Idempotency-Key":"frosttech-direct-quote:"+issued.invitation_id},
          body:JSON.stringify({from:EMAIL_FROM,to:[quote.customer_email],subject:"FrostTech Quotation "+quote.quotation_number,html})
        });
        const result=await sent.json().catch(()=>({}));
        emailSent=sent.ok;
        emailMessage=sent.ok?"Invitation email accepted by the email provider.":"Invitation created, but email delivery failed. Copy the secure link and send it to the customer.";
        if(!sent.ok) console.error("Direct quotation invitation email failed:",result);
      } catch(e) {
        console.error("Direct quotation invitation email error:",e);
      }
    }

    return response({
      success:true,
      message:"Quotation issued successfully.",
      quotation_number:issued.quotation_number,
      administration_fee:issued.administration_fee,
      fee_status:issued.fee_status,
      email_sent:emailSent,
      email_message:emailMessage,
      invitation_url:invitationUrl,
      invitation_expires_at:issued.invitation_expires_at
    },200,origin);
  } catch(error) {
    console.error("Issue direct quotation error:",error);
    return response({error:"An unexpected error occurred while issuing the quotation."},500,origin);
  }
});