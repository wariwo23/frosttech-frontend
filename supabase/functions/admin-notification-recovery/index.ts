import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const EMAIL_FROM = Deno.env.get("EMAIL_FROM") ?? "";
const ALLOWED_ORIGIN = "https://wariwo23.github.io";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function respond(body: Record<string, unknown>, status = 200, origin: string | null = null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin": origin === ALLOWED_ORIGIN ? origin : "null",
      "Content-Type": "application/json",
    },
  });
}

function adminClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") {
    if (origin && origin !== ALLOWED_ORIGIN) return respond({ error: "Origin not allowed" }, 403, origin);
    return new Response("ok", { headers: { ...corsHeaders, "Access-Control-Allow-Origin": origin || "null" } });
  }
  if (origin !== ALLOWED_ORIGIN) return respond({ error: "Origin not allowed" }, 403, origin);
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405, origin);

  const authorization = req.headers.get("Authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match || !SUPABASE_URL || !SUPABASE_ANON_KEY || !SERVICE_ROLE_KEY) {
    return respond({ error: "Authenticated Super Administrator session required" }, 401, origin);
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser(match[1].trim());
  if (authError || !user) return respond({ error: "Invalid or expired session" }, 401, origin);

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).byteLength > 8192) return respond({ error: "Request too large" }, 413, origin);
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Invalid body");
    body = parsed;
  } catch {
    return respond({ error: "Invalid request body" }, 400, origin);
  }

  const admin = adminClient();
  const action = body.action;

  try {
    if (action === "list") {
      const { data, error } = await admin.rpc("admin_list_notification_events", {
        p_limit: Math.min(100, Math.max(1, Number(body.limit) || 50)),
        p_offset: Math.max(0, Number(body.offset) || 0),
      });
      if (error) throw error;
      return respond({ ok: true, events: data ?? [] }, 200, origin);
    }

    if (action !== "recover") return respond({ error: "Unsupported action" }, 400, origin);
    if (typeof body.event_id !== "string" || typeof body.reason !== "string") {
      return respond({ error: "Event and recovery reason are required" }, 400, origin);
    }

    const { data: recovery, error: beginError } = await admin.rpc("admin_begin_notification_recovery", {
      p_event_id: body.event_id,
      p_reason: body.reason,
      p_confirm: body.confirm === true,
    });
    if (beginError) {
      const status = /Super Administrator|not authorized/i.test(beginError.message) ? 403 : 409;
      return respond({ error: beginError.message }, status, origin);
    }

    // Do not change recipient, event key, or payload. Reuse the original stable idempotency key.
    let result: Record<string, unknown> = {};
    let finalStatus: "sent" | "failed" = "failed";
    let errorText: string | null = null;
    let providerMessageId: string | null = null;

    try {
      if (!RESEND_API_KEY || !EMAIL_FROM) throw new Error("Email provider is not configured");
      const p = recovery.payload ?? {};
      const esc = (value: unknown) => String(value ?? "")
        .replaceAll("&", "&amp;").replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;").replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
      let subject = "";
      let html = "";

      if (recovery.event_key.startsWith("quote_request_customer:")) {
        subject = `FrostTech – Quotation Request Received – ${String(p.request_number ?? "")}`;
        html = `<div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
          <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
          <p>Hello ${esc(p.customer_name)},</p><p>Your quotation request has been received successfully.</p>
          <p><strong>Request Number:</strong> ${esc(p.request_number)}</p>
          <p>Our team will review your request and contact you.</p><p>Thank you for choosing FrostTech.</p></div>`;
      } else if (recovery.event_key.startsWith("quote_request:")) {
        subject = "New FrostTech Quotation Request";
        html = `<div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
          <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
          <p>A customer has submitted a new quotation request.</p>
          <p><strong>Customer Name:</strong> ${esc(p.customer_name || "Not provided")}</p>
          <p><strong>Customer Email:</strong> ${esc(p.customer_email || "Not provided")}</p>
          <p><strong>Customer Phone:</strong> ${esc(p.customer_phone || "Not provided")}</p>
          <p><strong>Request Number:</strong> ${esc(p.request_number)}</p>
          <p>Please log in to the FrostTech Administration Dashboard to review the quotation.</p></div>`;
      } else if (recovery.event_key.startsWith("advertiser_application_confirmation:")) {
        subject = "FrostTech – Advertiser Application Received";
        html = `<div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
          <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
          <p>Your advertiser application has been received successfully.</p>
          <p>Our team will review your submission and contact you regarding the next steps.</p>
          <p>Thank you for your interest in FrostTech.</p></div>`;
      } else if (recovery.event_key.startsWith("advertiser_application:")) {
        subject = "New FrostTech Advertiser Application";
        html = `<div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
          <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
          <p>A new advertiser application has been submitted.</p>
          <p>Please log in to the FrostTech Administration Dashboard to review the application.</p></div>`;
      } else {
        throw new Error("Unsupported notification event key; stopped before provider call");
      }

      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `frosttech:${recovery.event_key}`,
        },
        body: JSON.stringify({ from: EMAIL_FROM, to: [recovery.recipient], subject, html }),
      });
      result = await response.json().catch(() => ({}));
      if (!response.ok) {
        errorText = JSON.stringify(result).slice(0, 2000);
      } else {
        finalStatus = "sent";
        providerMessageId = typeof result.id === "string" ? result.id : null;
      }
    } catch (error) {
      errorText = String(error).slice(0, 2000);
    }

    const { error: finishError } = await admin.rpc("admin_finish_notification_recovery", {
      p_event_id: recovery.event_id,
      p_claim_token: recovery.claim_token,
      p_status: finalStatus,
      p_provider_message_id: providerMessageId,
      p_error: errorText,
    });
    if (finishError) {
      // The event may have been accepted by Resend. Do not initiate another send here.
      console.error("Recovery result could not be committed; provider outcome may be uncertain", finishError);
      return respond({ ok: false, uncertain: true, error: "Provider was contacted, but the result could not be recorded. Do not retry until reconciled." }, 202, origin);
    }

    return respond({
      ok: finalStatus === "sent",
      status: finalStatus,
      provider_message_id: providerMessageId,
      error: errorText,
    }, finalStatus === "sent" ? 200 : 502, origin);
  } catch (error) {
    console.error("Notification recovery error", error);
    return respond({ error: "Notification recovery could not be completed" }, 500, origin);
  }
});
