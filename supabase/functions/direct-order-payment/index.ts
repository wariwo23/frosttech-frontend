import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
import {processDelivery} from "./delivery.ts";
const URL=Deno.env.get("SUPABASE_URL")??"",ANON=Deno.env.get("SUPABASE_ANON_KEY")??"",SERVICE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const SITE="https://wariwo23.github.io",APP="https://wariwo23.github.io/frosttech-frontend";
const cors={"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function out(body:Record<string,unknown>,status=200,origin:string|null=null){return new Response(JSON.stringify(body),{status,headers:{...cors,"Access-Control-Allow-Origin":!origin||origin===SITE?(origin||SITE):"null","Content-Type":"application/json"}});}
function paystackSecret(environment:string){return environment==="development"?Deno.env.get("PAYSTACK_TEST_SECRET_KEY"):null;}
async function hash(value:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,"0")).join("");}
function makeReference(){const b=new Uint8Array(8);crypto.getRandomValues(b);return "FT-DQO-"+Date.now()+"-"+Array.from(b).map(x=>x.toString(16).padStart(2,"0")).join("");}
function safe(v:unknown){return String(v??"");}

async function createReceipt(db:any,serviceKey:string,order:Record<string,any>,payment:Record<string,any>,user:any){
 try{
  const {data:tax,error:taxError}=await db.from("frosttech_tax_settings").select("vat_enabled").eq("id",1).maybeSingle();
  if(taxError||!tax||tax.vat_enabled===true)throw new Error("Tax settings do not permit receipt issuance.");
  const {data:existing,error:existingError}=await db.from("payment_receipts")
   .select("id,receipt_number,receipt_type,source_record_id,direct_quotation_id,payment_reference,customer_user_id,amount_received,payment_status,environment")
   .eq("payment_reference",payment.transaction_reference).maybeSingle();
  if(existingError)throw existingError;
  let receipt=existing;
  if(receipt){
   if(receipt.receipt_type!=="final_order_payment"||String(receipt.source_record_id)!==order.id||receipt.direct_quotation_id!==order.direct_quotation_id||receipt.customer_user_id!==user.id||Number(receipt.amount_received)!==Number(payment.amount)||receipt.payment_status!=="successful"||receipt.environment!==order.environment)throw new Error("Existing receipt reference does not match this order payment.");
  }else{
   const {data:bySource,error:sourceError}=await db.from("payment_receipts").select("id,receipt_number,receipt_type,source_record_id,direct_quotation_id,payment_reference,customer_user_id,amount_received,payment_status,environment").eq("receipt_type","final_order_payment").eq("source_record_id",order.id).maybeSingle();
   if(sourceError)throw sourceError;
   if(bySource){
    if(bySource.payment_reference!==payment.transaction_reference||bySource.direct_quotation_id!==order.direct_quotation_id||bySource.customer_user_id!==user.id||Number(bySource.amount_received)!==Number(payment.amount)||bySource.payment_status!=="successful"||bySource.environment!==order.environment)throw new Error("Order already has a different receipt payment reference.");
    receipt=bySource;
   }else{
    const {data:inserted,error:insertError}=await db.from("payment_receipts").insert({
     receipt_type:"final_order_payment",environment:order.environment,customer_user_id:user.id,
     customer_name:safe(user.user_metadata?.full_name||user.user_metadata?.name||"Customer"),
     customer_email:user.email||null,source_record_id:order.id,quote_request_id:null,direct_quotation_id:order.direct_quotation_id,order_id:order.id,
     payment_reference:payment.transaction_reference,payment_method:"paystack",
     description:"Final payment for FrostTech direct quotation order "+order.order_number,
     amount_before_vat:payment.amount,vat_status:"disabled",vat_rate:null,vat_mode:null,vat_amount:0,
     amount_received:payment.amount,currency:"NGN",payment_status:"successful",paid_at:payment.paid_at||new Date().toISOString()
    }).select("id,receipt_number").single();
    if(insertError||!inserted)throw insertError||new Error("Receipt insert returned no record.");
    receipt=inserted;
   }
  }
  if(!receipt)throw new Error("Receipt record could not be retrieved.");
  const response=await fetch(URL+"/functions/v1/issue-payment-receipt",{
   method:"POST",headers:{Authorization:"Bearer "+serviceKey,apikey:serviceKey,"Content-Type":"application/json"},
   body:JSON.stringify({receipt_id:receipt.id})
  });
  const result=await response.json().catch(()=>({}));
  return {receipt_id:receipt.id,receipt_number:receipt.receipt_number||null,processing:response.ok?(result.email_status==="sent"?"completed":result.document_status==="generated"?"pdf_generated":"pending"):"pending",message:result.message||"Receipt processing requested."};
 }catch(e){console.error("Direct order receipt processing deferred:",e);return {receipt_id:null,receipt_number:null,processing:"pending",message:"Payment is successful. Receipt processing requires follow-up."};}
}

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
  const {data:{user},error:authError}=await auth.auth.getUser(jwt);
  if(authError||!user?.email)return out({error:"Your customer session is invalid or expired."},401,origin);
  const body=await req.json().catch(()=>null);
  const action=String(body?.action||"");
  const orderId=typeof body?.order_id==="string"?body.order_id:"";
  const rawToken=typeof body?.token==="string"?body.token:"";
  if(!uuid.test(orderId)||rawToken.length<32||rawToken.length>128||!/^[A-Za-z0-9_-]+$/.test(rawToken))return out({error:"Invalid direct order payment request."},400,origin);

  const db=createClient(URL,SERVICE,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:profile,error:profileError}=await db.from("profiles")
    .select("id,role,is_active").eq("id",user.id).maybeSingle();
  if(profileError||!profile||profile.role!=="customer"||profile.is_active!==true)
    return out({error:"An active FrostTech customer account is required."},403,origin);
  const {data:invite,error:inviteError}=await db.from("frosttech_direct_quotation_invites")
   .select("id,claimed_by,token_hash,revoked_at,direct_quotation_id")
   .eq("token_hash",await hash(rawToken)).maybeSingle();
  if(inviteError||!invite||invite.claimed_by!==user.id||invite.revoked_at)return out({error:"This customer invitation is not linked to your account."},403,origin);

  const {data:order,error:orderError}=await db.from("orders")
   .select("id,order_number,customer_id,customer_total,delivery_fee,delivery_address,status,environment,direct_quotation_id")
   .eq("id",orderId).eq("direct_quotation_id",invite.direct_quotation_id).maybeSingle();
  if(orderError||!order)return out({error:"The direct quotation order could not be found."},404,origin);
  const {data:customer,error:customerError}=await db.from("customers").select("id,user_id").eq("id",order.customer_id).maybeSingle();
  if(customerError||!customer||customer.user_id!==user.id)return out({error:"This order does not belong to your customer account."},403,origin);
  const {data:quote,error:quoteError}=await db.from("frosttech_direct_quotations")
   .select("id,status,accepted_by,fee_status,order_payment_terms_accepted_at,environment,customer_email")
   .eq("id",order.direct_quotation_id).maybeSingle();
  if(quoteError||!quote||quote.status!=="accepted"||quote.accepted_by!==user.id||!["paid","waived"].includes(quote.fee_status)||quote.environment!==order.environment||String(quote.customer_email).trim().toLowerCase()!==user.email.trim().toLowerCase())
   return out({error:"The accepted quotation is not eligible for final payment from this customer account."},409,origin);

  if(action==="initialize_order"){
   if(body.terms_accepted!==true)return out({error:"Please accept the FrostTech General Terms and Conditions before final payment."},400,origin);
   if(order.status!=="awaiting_payment")return out({error:"This order is not awaiting payment."},409,origin);
   if(order.environment!=="development")return out({error:"Direct order payments are currently limited to Paystack Test Mode."},409,origin);
   const secret=paystackSecret(order.environment);if(!secret)return out({error:"Paystack Test Mode is not configured."},503,origin);
   const {error:termsError}=await db.from("frosttech_direct_quotations")
    .update({order_payment_terms_accepted_at:new Date().toISOString(),order_payment_terms_version:"general-terms-current",updated_at:new Date().toISOString()})
    .eq("id",quote.id).eq("status","accepted").eq("accepted_by",user.id);
   if(termsError)return out({error:"Your final-payment Terms acceptance could not be recorded. No payment was started."},500,origin);
   const amount=Number(order.customer_total),amountKobo=Math.round(amount*100);
   if(!Number.isSafeInteger(amountKobo)||amountKobo<=0)return out({error:"The stored order total is invalid."},409,origin);
   const proposedReference=makeReference();
   const {data:reservation,error:reservationError}=await db.rpc("frosttech_reserve_direct_order_payment",{
    p_order_id:order.id,p_actor:user.id,p_reference:proposedReference
   });
   if(reservationError||!reservation?.success){
    console.error("Direct order payment reservation failed:",reservationError);
    return out({error:"Could not safely reserve this order payment. No new checkout was started."},409,origin);
   }
   const payment={id:reservation.payment_id};
   const ref=String(reservation.reference||"");
   if(!ref||Number(reservation.amount)!==amount)return out({error:"The reserved payment does not match this order total. Reconciliation is required."},409,origin);
   if(reservation.reused===true){
    const {data:session,error:sessionLookupError}=await db.from("frosttech_direct_order_payment_sessions")
     .select("authorization_url").eq("payment_id",payment.id).maybeSingle();
    if(sessionLookupError)return out({error:"Could not retrieve the existing checkout session. Please retry shortly."},500,origin);
    if(session?.authorization_url)return out({success:true,authorization_url:session.authorization_url,reference:ref,amount:reservation.amount,reused:true},200,origin);
    return out({error:"A payment initialization is already in progress or requires reconciliation. Do not start another payment attempt."},409,origin);
   }
   let init:Response;
   try{
    init=await fetch("https://api.paystack.co/transaction/initialize",{
     method:"POST",headers:{Authorization:"Bearer "+secret,"Content-Type":"application/json"},
     body:JSON.stringify({email:user.email,amount:amountKobo,currency:"NGN",reference:ref,
      callback_url:APP+"/direct-quotation.html?token="+encodeURIComponent(rawToken)+"&order_id="+encodeURIComponent(order.id),
      metadata:{order_id:order.id,direct_quotation_id:quote.id,order_number:order.order_number,payment_type:"direct_quotation_order_payment",frosttech_environment:"development"}})
    });
   }catch(e){console.error("Direct order Paystack init outcome uncertain:",e);return out({error:"Paystack did not return a confirmation. This attempt is held for reconciliation; do not retry yet."},502,origin);}
   const initResult=await init.json().catch(()=>({}));
   if(!init.ok||initResult.status!==true||!initResult.data?.authorization_url){
    await db.from("payments").update({status:"failed",updated_at:new Date().toISOString()}).eq("id",payment.id).eq("status","pending");
    return out({error:"Paystack could not initialize this order payment."},502,origin);
   }
   const {error:sessionError}=await db.from("frosttech_direct_order_payment_sessions").insert({
    order_id:order.id,payment_id:payment.id,authorization_url:initResult.data.authorization_url,environment:"development",updated_at:new Date().toISOString()
   });
   if(sessionError)return out({error:"Paystack initialized, but the secure checkout record could not be saved. Contact FrostTech before proceeding."},500,origin);
   return out({success:true,authorization_url:initResult.data.authorization_url,reference:ref,amount,reused:false},200,origin);
  }

  if(action==="verify_order"){
   if(!quote.order_payment_terms_accepted_at)return out({error:"Final-payment Terms acceptance has not been recorded."},403,origin);
   let ref=typeof body.reference==="string"?body.reference.trim():"";
   if(!ref){
    // Prefer a confirmed payment over a newer unfinished attempt so recovery
    // never overlooks money already received for this order.
    const paymentLookup=db.from("payments")
     .select("transaction_reference")
     .eq("order_id",order.id)
     .eq("payment_method","paystack")
     .eq("environment",order.environment)
     .eq("status","successful")
     .order("created_at",{ascending:false})
     .limit(1)
     .maybeSingle();
    const {data:successful,error:successfulError}=await paymentLookup;
    if(successfulError)return out({error:"The existing successful payment could not be located. Please try again shortly."},500,origin);
    if(successful?.transaction_reference){
     ref=String(successful.transaction_reference);
    }else{
     const {data:pending,error:pendingError}=await db.from("payments")
      .select("transaction_reference")
      .eq("order_id",order.id)
      .eq("payment_method","paystack")
      .eq("environment",order.environment)
      .eq("status","pending")
      .order("created_at",{ascending:false})
      .limit(1)
      .maybeSingle();
     if(pendingError)return out({error:"The pending payment attempt could not be located. Please try again shortly."},500,origin);
     ref=String(pending?.transaction_reference||"");
    }
   }
   if(!ref||ref.length>120)return out({error:"No pending or successful payment attempt was found for this order."},404,origin);
   const {data:payment,error:paymentError}=await db.from("payments")
    .select("id,amount,currency,payment_method,transaction_reference,status,environment,paid_at")
    .eq("order_id",order.id).eq("transaction_reference",ref).maybeSingle();
   if(paymentError||!payment)return out({error:"Order payment attempt could not be found."},404,origin);
   if(payment.payment_method!=="paystack"||payment.currency!=="NGN"||payment.environment!==order.environment
      ||Number(payment.amount)!==Number(order.customer_total)||payment.transaction_reference!==ref){
    return out({error:"The recorded payment does not match this order's Paystack amount, currency or environment. FrostTech reconciliation is required."},409,origin);
   }
   if(payment.status!=="successful"){
    if(payment.status!=="pending"||payment.environment!=="development"||order.environment!=="development")return out({error:"This payment attempt is not eligible for verification."},409,origin);
    const secret=paystackSecret(payment.environment);if(!secret)return out({error:"Paystack Test Mode is not configured."},503,origin);
    const verification=await fetch("https://api.paystack.co/transaction/verify/"+encodeURIComponent(ref),{method:"GET",headers:{Authorization:"Bearer "+secret,Accept:"application/json"}});
    const result=await verification.json().catch(()=>({})),tx=result.data;
    if(!verification.ok||result.status!==true||!tx||tx.reference!==ref||String(tx.status).toLowerCase()!=="success"||String(tx.currency).toUpperCase()!=="NGN"||Number(tx.amount)!==Math.round(Number(payment.amount)*100)||Number(payment.amount)!==Number(order.customer_total)){
     return out({error:"Paystack has not confirmed the exact order amount in NGN. The payment remains unverified."},409,origin);
    }
    const {data:recorded,error:recordError}=await db.rpc("frosttech_record_direct_order_payment_success",{
     p_order_id:order.id,p_payment_id:payment.id,p_actor:user.id,p_reference:ref,
     p_provider_transaction_id:String(tx.id),p_verified_at:new Date().toISOString(),
     p_verification_payload:{reference:tx.reference,status:tx.status,amount:tx.amount,currency:tx.currency,channel:tx.channel,paid_at:tx.paid_at}
    });
    if(recordError||!recorded?.success){console.error("Direct order payment record failed:",recordError);return out({error:"Paystack confirmed payment, but FrostTech could not complete the order record. Contact support with reference "+ref+"."},500,origin);}
   }else{
    // Repair an interrupted order-status update for a payment already verified by Paystack.
    const {data:recorded,error:recordError}=await db.rpc("frosttech_record_direct_order_payment_success",{
     p_order_id:order.id,p_payment_id:payment.id,p_actor:user.id,p_reference:ref,
     p_provider_transaction_id:null,p_verified_at:payment.paid_at||new Date().toISOString(),
     p_verification_payload:{reference:ref,status:"success",amount:Math.round(Number(payment.amount)*100),currency:"NGN",reconciled_existing_success:true}
    });
    if(recordError||!recorded?.success){console.error("Existing successful payment reconciliation failed:",recordError);return out({error:"The payment is already recorded, but the order status could not be reconciled. Contact FrostTech support."},500,origin);}
   }
   const {data:paidOrder,error:paidOrderError}=await db.from("orders")
    .select("id,order_number,customer_id,customer_total,delivery_fee,delivery_address,status,environment,direct_quotation_id")
    .eq("id",order.id).maybeSingle();
   if(paidOrderError||!paidOrder||paidOrder.status!=="paid")return out({error:"Payment is recorded but order status needs FrostTech reconciliation."},500,origin);

   let deliveryResult:any={deliveryCreated:false,existingDelivery:false,deliveryId:null,deliveryStatus:null,needsAdminReview:false,reviewReasons:[] as string[]};
   if(paidOrder.environment==="production"){
    const {data:items,error:itemsError}=await db.from("order_items").select("product_id").eq("order_id",order.id);
    if(itemsError){deliveryResult.needsAdminReview=true;deliveryResult.reviewReasons.push("Order product categories could not be checked.");}
    else{
     const productIds=[...new Set((items||[]).map(x=>x.product_id).filter(Boolean))] as string[];
     if(productIds.length){
      const {data:products,error:productsError}=await db.from("products").select("id,category").in("id",productIds);
      if(productsError){deliveryResult.needsAdminReview=true;deliveryResult.reviewReasons.push("Order product categories could not be verified.");}
      else{
       const categories=(products||[]).map(p=>p.category).filter(Boolean);
       const allEligible=products?.length===productIds.length&&categories.length===productIds.length&&categories.every(c=>["Air Conditioners","Refrigeration Parts","HVAC Accessories"].includes(c));
       deliveryResult=await processDelivery(db,{id:paidOrder.id,status:paidOrder.status,delivery_fee:paidOrder.delivery_fee,delivery_address:paidOrder.delivery_address},allEligible?categories[0]:null,true,!allEligible);
      }
     }
    }
   }

   const {data:customer}=await db.from("customers").select("full_name,email").eq("id",paidOrder.customer_id).maybeSingle();
   const receipt=await createReceipt(db,SERVICE,paidOrder,payment,{id:user.id,email:user.email,user_metadata:{full_name:customer?.full_name||user.user_metadata?.full_name||"Customer"}});
   return out({success:true,order_number:paidOrder.order_number,order_status:paidOrder.status,amount:paidOrder.customer_total,delivery:deliveryResult,receipt},200,origin);
  }
  return out({error:"Unsupported direct order payment action."},400,origin);
 }catch(e){console.error("Direct order payment error:",e);return out({error:"Unable to process the direct order payment request."},500,origin);}
});