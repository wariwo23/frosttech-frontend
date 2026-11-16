import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGIN = "https://wariwo23.github.io";
const MAX_BODY_BYTES = 32000;

function json(body: Record<string, unknown>, status = 200, origin: string | null = null) {
  const allowed = !origin || origin === ALLOWED_ORIGIN;
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": allowed ? (origin || ALLOWED_ORIGIN) : "null",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Vary": "Origin",
    },
  });
}
function text(value: unknown, max: number): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}
function validUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: {
    "Access-Control-Allow-Origin": origin === ALLOWED_ORIGIN ? origin : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  }});
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405, origin);
  if (origin && origin !== ALLOWED_ORIGIN) return json({ error: "Origin not allowed." }, 403, origin);

  const authorization = req.headers.get("Authorization") ?? "";
  const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return json({ error: "A verified FrostTech Guest session is required." }, 401, origin);
  const length = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) return json({ error: "Request is too large." }, 413, origin);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: "Guest quotation service is not configured." }, 500, origin);
  }

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return json({ error: "Request is too large." }, 413, origin);
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return json({ error: "Invalid request." }, 400, origin);
    body = parsed as Record<string, unknown>;
  } catch {
    return json({ error: "Invalid request." }, 400, origin);
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    const { data: userData, error: userError } = await userClient.auth.getUser(tokenMatch[1]);
    const user = userData.user;
    if (userError || !user) return json({ error: "Guest session is invalid or expired. Please verify your email again." }, 401, origin);
    if (!user.email_confirmed_at) return json({ error: "Confirm your email address before submitting a quotation." }, 403, origin);
    if (user.app_metadata?.account_type !== "guest") return json({ error: "This identity is not an activated FrostTech Guest." }, 403, origin);
    const customerName = text(user.user_metadata?.full_name, 150);
    const customerPhone = text(user.user_metadata?.phone, 30);
    const customerEmail = text(user.email, 254).toLowerCase();
    if (!customerName || !customerPhone || !customerEmail) return json({ error: "Your verified guest details are incomplete. Please contact FrostTech support." }, 400, origin);

    const { data: profile, error: profileError } = await admin.from("profiles").select("id").eq("id", user.id).maybeSingle();
    if (profileError) throw profileError;
    if (profile) return json({ error: "This identity has a customer profile. Please use the registered customer quotation journey." }, 403, origin);

    const request = body.request;
    if (!request || typeof request !== "object" || Array.isArray(request)) return json({ error: "Quotation details are missing." }, 400, origin);
    const r = request as Record<string, unknown>;

    const title = text(r.title, 250);
    const descriptionInput = text(r.description, 12000);
    const quantity = Number(r.quantity);
    const deliveryAddress = text(r.delivery_address, 1000);
    const preferredBrand = text(r.preferred_brand, 150) || null;
    const budget = r.budget === null || r.budget === undefined || r.budget === "" ? null : Number(r.budget);
    if (!title || !descriptionInput || !Number.isInteger(quantity) || quantity < 1 || quantity > 10000 || !deliveryAddress) {
      return json({ error: "Please provide a valid product or service request, quantity and delivery address." }, 400, origin);
    }
    if (budget !== null && (!Number.isFinite(budget) || budget <= 0 || budget > 100000000000)) {
      return json({ error: "The quotation budget is invalid." }, 400, origin);
    }

    let productId: string | null = null;
    if (r.product_id !== undefined && r.product_id !== null && r.product_id !== "") {
      productId = text(r.product_id, 64);
      if (!validUuid(productId)) return json({ error: "The selected catalogue product is invalid." }, 400, origin);
      const { data: product, error: productError } = await admin.from("products").select("id").eq("id", productId).eq("is_active", true).maybeSingle();
      if (productError) throw productError;
      if (!product) return json({ error: "The selected catalogue product is no longer available. Please refresh and select again." }, 400, origin);
    }

    // Rebuild identity lines from verified Auth data; never trust browser-supplied identity fields.
    const remainingLines = descriptionInput.split(/\r?\n/).filter((line) =>
      !/^\s*(customer|phone|email)\s*:/i.test(line)
    );
    const description = [
      "Customer: " + customerName,
      "Phone: " + customerPhone,
      "Email: " + customerEmail,
      ...remainingLines,
    ].join("\n");

    const requestNumber = "FT-" + Date.now() + "-" + crypto.randomUUID().slice(0, 5).toUpperCase();
    const insertRecord: Record<string, unknown> = {
      customer_id: null,
      customer_name: customerName,
      customer_phone: customerPhone,
      customer_email: customerEmail,
      request_number: requestNumber,
      title,
      description,
      quantity,
      preferred_brand: preferredBrand,
      budget,
      delivery_address: deliveryAddress,
    };
    if (productId) insertRecord.product_id = productId;

    const { data: saved, error: insertError } = await admin
      .from("quote_requests")
      .insert(insertRecord)
      .select("id, request_number")
      .single();
    if (insertError || !saved) {
      console.error("Guest quotation insert failed:", insertError);
      throw new Error("The quotation request could not be saved.");
    }

    // Keep the existing FrostTech notification event and idempotent notification workflow.
    try {
      await admin.functions.invoke("send-frosttech-notification", {
        body: { event_type: "quote_request_submitted", request_number: saved.request_number },
      });
    } catch (notificationError) {
      console.warn("Guest quotation notification did not complete:", notificationError);
    }

    return json({ ok: true, request_number: saved.request_number }, 200, origin);
  } catch (error) {
    console.error("Guest quotation submission failed:", error);
    return json({ error: error instanceof Error ? error.message : "Quotation submission failed. Please try again." }, 500, origin);
  }
});