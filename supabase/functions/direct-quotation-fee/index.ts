import { createClient } from "npm:@supabase/supabase-js@2";
const URL=Deno.env.get("SUPABASE_URL")??"";
const ANON=Deno.env.get("SUPABASE_ANON_KEY")??"";
const SERVICE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const SITE="https://wariwo23.github.io";
const APP="https://wariwo23.github.io/frosttech-frontend";
const cors={"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function out(body:Record<string,unknown>,status=200,origin:string|null=null){
 return new Response(JSON.stringify(body),{status,headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null","Content-Type":"application/json"}});
}
function secret(environment:string){return environment==="development"?Deno.env.get("PAYSTACK_TEST_SECRET_KEY"):null;}
function reference(){const b=new Uint8Array(8);crypto.getRandomValues(b);return "FT-DQF-"+Date.now()+"-"+Array.from(b).map(x=>x.toString(16).padStart(2,"0")).join("");}
async function sha(value:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,"0")).join("");}

async function issueFeeReceipt(db:ReturnType<typeof createClient>,serviceKey:string,quote:Record<string,any>,attempt:Record<string,any>,user:Record<string,any>){
 try{
  const {data:tax,error:taxError}=await db.from("frosttech_tax_settings").select("vat_enabled").eq("id",1).maybeSingle();
  if(taxError||!tax||tax.vat_enabled===true)throw new Error("Tax settings do not permit receipt issuance.");
  const {data:byRef,error:refError}=await db.from("payment_receipts")
   .select("id,receipt_number,receipt_type,source_record_id,payment_reference,customer_user_id,amount_received,payment_status,environment")
   .eq("payment_reference",attempt.provider_reference).maybeSingle();
  if(refError)throw refError;
  let receipt=byRef;
  if(receipt){
   if(receipt.receipt_type!=="quotation_admin_fee"||String(receipt.source_record_id)!==quote.id||receipt.customer_user_id!==user.id||Number(receipt.amount_received)!==Number(attempt.amount)||receipt.payment_status!=="successful"||receipt.environment!==attempt.environment)
    throw new Error("Existing receipt reference does not match this direct quotation fee.");
  }else{
   const {data:bySource,error:sourceError}=await db.from("payment_receipts")
    .select("id,receipt_number,receipt_type,source_record_id,payment_reference,customer_user_id,amount_received,payment_status,environment")
    .eq("receipt_type","quotation_admin_fee").eq("source_record_id",quote.id).maybeSingle();
   if(sourceError)throw sourceError;
   if(bySource){
    if(bySource.payment_reference!==attempt.provider_reference||bySource.customer_user_id!==user.id||Number(bySource.amount_received)!==Number(attempt.amount)||bySource.payment_status!=="successful"||bySource.environment!==attempt.environment)
     throw new Error("Direct quotation already has a different fee receipt.");
    receipt=bySource;
   }else{
    const {data:inserted,error:insertError}=await db.from("payment_receipts").insert({
     receipt_type:"quotation_admin_fee",environment:attempt.environment,customer_user_id:user.id,
     customer_name:quote.customer_name||"Customer",customer_email:user.email||quote.customer_email,
     source_record_id:quote.id,quote_request_id:null,order_id:null,
     payment_reference:attempt.provider_reference,payment_method:"paystack",
     description:"Quotation Processing and Marketplace Administration Fee for "+quote.quotation_number,
     amount_before_vat:attempt.amount,vat_status:"disabled",vat_rate:null,vat_mode:null,vat_amount:0,
     amount_received:attempt.amount,currency:"NGN",payment_status:"successful",paid_at:attempt.verified_at||new Date().toISOString()
    }).select("id,receipt_number").single();
    if(insertError||!inserted)throw insertError||new Error("Receipt record could not be created.");
    receipt=inserted;
   }
  }
  const res=await fetch(URL+"/functions/v1/issue-payment-receipt",{
   method:"POST",headers:{Authorization:"Bearer "+serviceKey,apikey:serviceKey,"Content-Type":"application/json"},
   body:JSON.stringify({receipt_id:receipt.id})
  });
  const result=await res.json().catch(()=>({}));
  return {receipt_id:receipt.id,receipt_number:receipt.receipt_number||null,processing:res.ok?(result.email_status==="sent"?"completed":result.document_status==="generated"?"pdf_generated":"pending"):"pending",message:result.message||"Receipt processing requested."};
 }catch(e){console.error("Direct quotation fee receipt processing deferred:",e);return {receipt_id:null,receipt_number:null,processing:"pending",message:"Fee payment is successful. Receipt processing requires follow-up."};}
}

Deno.serve(async(req:Request)=>{
 const origin=req.headers.get("Origin");
 if(req.method==="OPTIONS")return new Response("ok",{headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null"}});
 if(req.method!=="POST")return out({error:"POST requests only."},405,origin);
 if(origin&&origin!==SITE)return out({error:"Origin not allowed."},403,origin);
 try{
  const authHeader=req.headers.get("Authorization")||"";
  if(!authHeader.startsWith("Bearer "))return out({error:"Customer sign-in required."},401,origin);
  const jwt=authHeader.slice(7);
  const auth=createClient(URL,ANON,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error:authError}=await auth.auth.getUser(jwt);
  if(authError||!user?.email)return out({error:"Your customer session is invalid or expired."},401,origin);
  const body=await req.json().catch(()=>null);
  const quoteId=typeof body?.quotation_id==="string"?body.quotation_id:"";
  const rawToken=typeof body?.token==="string"?body.token:"";
  if(!uuid.test(quoteId)||rawToken.length<32||rawToken.length>128)return out({error:"Invalid quotation payment request."},400,origin);
  const db=createClient(URL,SERVICE,{auth:{persistSession:false,autoRefreshToken:false}});
  const tokenHash=await sha(rawToken);
  const {data:invite,error:inviteError}=await db.from("frosttech_direct_quotation_invites")
    .select("id,claimed_by,expires_at,revoked_at,used_at,direct_quotation_id,token_hash")
    .eq("token_hash",tokenHash).eq("direct_quotation_id",quoteId).maybeSingle();
  const action=String(body?.action||"");
  if(inviteError||!invite||invite.claimed_by!==user.id||(action==="initialize_fee"&&invite.expires_at<=new Date().toISOString())||invite.revoked_at||invite.used_at)
    return out({error:"Please verify your customer invitation again."},403,origin);
  const {data:quote,error:quoteError}=await db.from("frosttech_direct_quotations")
    .select("id,quotation_number,customer_name,customer_email,administration_fee,fee_status,environment,status,prepayment_terms_accepted_at")
    .eq("id",quoteId).maybeSingle();
  if(quoteError||!quote||quote.status!=="submitted"||String(quote.customer_email).trim().toLowerCase()!==user.email.trim().toLowerCase())
    return out({error:"The quotation is not available to this customer account."},404,origin);

  if(body.action==="initialize_fee"){
    if(quote.fee_status==="paid"||quote.fee_status==="waived")return out({error:"This quotation processing fee has already been settled."},409,origin);
    if(quote.fee_status!=="pending"||Number(quote.administration_fee)<=0)return out({error:"No payable quotation processing fee is due."},409,origin);
    if(body.terms_accepted!==true)return out({error:"Please read and accept the FrostTech General Terms and Conditions before payment."},400,origin);
    if(quote.environment!=="development")return out({error:"This direct quotation is not enabled for payment in its current environment."},409,origin);
    const paystackSecret=secret(quote.environment);
    if(!paystackSecret)return out({error:"Paystack Test Mode is not configured. No payment was started."},503,origin);

    if(!quote.prepayment_terms_accepted_at){
      const {error:termsError}=await db.from("frosttech_direct_quotations")
        .update({prepayment_terms_accepted_at:new Date().toISOString(),prepayment_terms_version:"general-terms-current",updated_at:new Date().toISOString()})
        .eq("id",quoteId).eq("status","submitted").eq("fee_status","pending");
      if(termsError)return out({error:"Your Terms acceptance could not be recorded. No payment was started."},500,origin);
    }

    const {data:pending,error:pendingError}=await db.from("frosttech_direct_quote_fee_payments")
      .select("id,provider_reference,amount,authorization_url,status,environment")
      .eq("direct_quotation_id",quoteId).eq("status","pending").maybeSingle();
    if(pendingError)return out({error:"Could not check existing payment attempts."},500,origin);
    if(pending){
      if(pending.environment!=="development")return out({error:"A payment attempt exists in another environment. FrostTech reconciliation is required."},409,origin);
      if(pending.authorization_url)return out({success:true,authorization_url:pending.authorization_url,reference:pending.provider_reference,amount:pending.amount,reused:true},200,origin);
      return out({error:"A previous payment initialization has an uncertain outcome. Please contact FrostTech before retrying."},409,origin);
    }

    const amount=Number(quote.administration_fee);
    const amountKobo=Math.round(amount*100);
    if(!Number.isSafeInteger(amountKobo)||amountKobo<=0)return out({error:"The stored quotation fee is invalid."},409,origin);
    const ref=reference();
    const idempotency=crypto.randomUUID();
    const {data:attempt,error:insertError}=await db.from("frosttech_direct_quote_fee_payments").insert({
      direct_quotation_id:quoteId,amount,currency:"NGN",provider:"paystack",
      provider_reference:ref,idempotency_key:idempotency,status:"pending",environment:"development"
    }).select("id").single();
    if(insertError||!attempt)return out({error:"Could not reserve the payment attempt. No checkout was started."},409,origin);

    const callback=APP+"/direct-quotation.html?token="+encodeURIComponent(rawToken);
    let initialized:Response;
    try{
      initialized=await fetch("https://api.paystack.co/transaction/initialize",{
        method:"POST",headers:{Authorization:"Bearer "+paystackSecret,"Content-Type":"application/json"},
        body:JSON.stringify({
          email:user.email,amount:amountKobo,currency:"NGN",reference:ref,callback_url:callback,
          metadata:{direct_quotation_id:quoteId,quotation_number:quote.quotation_number,payment_type:"direct_quotation_admin_fee",frosttech_environment:"development",frosttech_fee_percentage:2}
        })
      });
    }catch(e){
      console.error("Paystack initialization outcome uncertain:",e);
      return out({error:"Paystack did not return a confirmation. The attempt is held safely for reconciliation; do not retry yet."},502,origin);
    }
    const initResult=await initialized.json().catch(()=>({}));
    if(!initialized.ok||initResult.status!==true||!initResult.data?.authorization_url){
      await db.from("frosttech_direct_quote_fee_payments").update({status:"failed",updated_at:new Date().toISOString()}).eq("id",attempt.id).eq("status","pending");
      console.error("Paystack direct fee initialization rejected:",initResult);
      return out({error:"Paystack could not initialize this payment. No checkout link was issued."},502,origin);
    }
    const {error:updateError}=await db.from("frosttech_direct_quote_fee_payments")
      .update({authorization_url:initResult.data.authorization_url,provider_transaction_id:initResult.data.access_code||null,updated_at:new Date().toISOString()})
      .eq("id",attempt.id).eq("status","pending");
    if(updateError)return out({error:"Paystack initialized but the checkout record could not be updated. Contact FrostTech before proceeding."},500,origin);
    return out({success:true,authorization_url:initResult.data.authorization_url,reference:ref,amount,reused:false},200,origin);
  }

  if(body.action==="verify_fee"){
    const ref=typeof body.reference==="string"?body.reference.trim():"";
    if(!ref||ref.length>100)return out({error:"Paystack reference is required."},400,origin);
    const {data:attempt,error:attemptError}=await db.from("frosttech_direct_quote_fee_payments")
      .select("id,amount,currency,provider_reference,status,environment")
      .eq("direct_quotation_id",quoteId).eq("provider_reference",ref).maybeSingle();
    if(attemptError||!attempt)return out({error:"The payment attempt could not be found."},404,origin);
    if(attempt.status==="successful"){
      const receipt=await issueFeeReceipt(db,SERVICE,quote,attempt,user);
      return out({success:true,already_verified:true,receipt},200,origin);
    }
    if(attempt.status!=="pending"||attempt.environment!=="development"||quote.environment!=="development")
      return out({error:"This payment attempt is not eligible for verification."},409,origin);
    const paystackSecret=secret(attempt.environment);
    if(!paystackSecret)return out({error:"Paystack Test Mode is not configured."},503,origin);
    const verification=await fetch("https://api.paystack.co/transaction/verify/"+encodeURIComponent(ref),{
      method:"GET",headers:{Authorization:"Bearer "+paystackSecret,Accept:"application/json"}
    });
    const result=await verification.json().catch(()=>({}));
    const tx=result.data;
    if(!verification.ok||result.status!==true||!tx||tx.reference!==ref||String(tx.status).toLowerCase()!=="success"||String(tx.currency).toUpperCase()!=="NGN"||Number(tx.amount)!==Math.round(Number(attempt.amount)*100)){
      return out({error:"Paystack has not confirmed the exact expected amount in NGN. The payment remains unverified."},409,origin);
    }
    const {data:recorded,error:recordError}=await db.rpc("frosttech_record_direct_quote_fee_success",{
      p_quote_id:quoteId,p_payment_id:attempt.id,p_actor:user.id,p_reference:ref,
      p_provider_transaction_id:String(tx.id),p_verified_at:new Date().toISOString(),
      p_verification_payload:{reference:tx.reference,status:tx.status,amount:tx.amount,currency:tx.currency,channel:tx.channel,paid_at:tx.paid_at}
    });
    if(recordError||!recorded?.success){
      console.error("Verified direct fee could not be recorded:",recordError);
      return out({error:"Paystack confirmed payment, but FrostTech could not record it yet. Please contact support with reference "+ref+"."},500,origin);
    }
    const receipt=await issueFeeReceipt(db,SERVICE,{...quote,id:quote.id},{
      ...attempt,provider_reference:ref,verified_at:new Date().toISOString()
    },user);
    return out({success:true,already_verified:recorded.already_recorded===true,receipt},200,origin);
  }
  return out({error:"Unsupported payment action."},400,origin);
 }catch(e){
  console.error("Direct quotation fee handler error:",e);
  return out({error:"Unable to process this quotation fee request."},500,origin);
 }
});