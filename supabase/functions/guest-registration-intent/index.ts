import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGIN = "https://wariwo23.github.io";
const MAX_BODY_BYTES = 4096;
function json(body: Record<string, unknown>, status = 200, origin: string | null = null) {
  const allowed = !origin || origin === ALLOWED_ORIGIN;
  return new Response(JSON.stringify(body), { status, headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": allowed ? (origin || ALLOWED_ORIGIN) : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin",
  }});
}
function clean(value: unknown, max: number): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}
async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: {
    "Access-Control-Allow-Origin": origin === ALLOWED_ORIGIN ? origin : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin",
  }});
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405, origin);
  if (origin && origin !== ALLOWED_ORIGIN) return json({ error: "Origin not allowed." }, 403, origin);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return json({ error: "Guest registration service is not configured." }, 500, origin);
  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return json({ error: "Request is too large." }, 413, origin);
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return json({ error: "Invalid registration details." }, 400, origin);
    body = parsed as Record<string, unknown>;
  } catch { return json({ error: "Invalid registration details." }, 400, origin); }
  const fullName = clean(body.full_name, 150);
  const phone = clean(body.phone, 30);
  const email = clean(body.email, 254).toLowerCase();
  if (!fullName || !phone || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "Please provide a valid name, phone number and email address." }, 400, origin);
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  try {
    // Limit repeated registration-proof creation for the same email address.
    const { count, error: rateError } = await admin
      .from("guest_registration_intents")
      .select("id", { count: "exact", head: true })
      .eq("email", email)
      .gte("created_at", new Date(Date.now() - 30 * 60 * 1000).toISOString());
    if (rateError) throw rateError;
    if ((count ?? 0) >= 3) {
      return json({ error: "Too many Guest registration attempts for this email. Please wait 30 minutes and try again." }, 429, origin);
    }

    const token = crypto.randomUUID() + "." + crypto.randomUUID();
    const tokenHash = await sha256(token);
    const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();
    const { error } = await admin.from("guest_registration_intents").insert({
      email, full_name: fullName, phone, registration_token_hash: tokenHash, expires_at: expiresAt,
    });
    if (error) throw error;
    return json({ ok: true, registration_token: token }, 200, origin);
  } catch (error) {
    console.error("Guest registration intent failed:", error);
    return json({ error: "FrostTech could not prepare your Guest registration. Please try again." }, 500, origin);
  }
});