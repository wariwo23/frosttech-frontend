import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGIN = "https://wariwo23.github.io";
function response(body: Record<string, unknown>, status = 200, origin: string | null = null) {
  const allowed = !origin || origin === ALLOWED_ORIGIN;
  return new Response(JSON.stringify(body), { status, headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": allowed ? (origin || ALLOWED_ORIGIN) : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin",
  }});
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
  if (req.method !== "POST") return response({ error: "Method not allowed." }, 405, origin);
  if (origin && origin !== ALLOWED_ORIGIN) return response({ error: "Origin not allowed." }, 403, origin);
  const tokenMatch = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return response({ error: "A valid Guest session is required." }, 401, origin);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) return response({ error: "Guest verification service is not configured." }, 500, origin);

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    const { data: userData, error: userError } = await userClient.auth.getUser(tokenMatch[1]);
    const user = userData.user;
    if (userError || !user) return response({ error: "Guest session is invalid or expired." }, 401, origin);
    if (!user.email_confirmed_at) return response({ error: "Confirm your email address before continuing." }, 403, origin);
    if (user.app_metadata?.account_type === "guest") return response({ ok: true, identity: "guest" }, 200, origin);

    const token = String(user.user_metadata?.guest_registration_token ?? "");
    const fullName = String(user.user_metadata?.full_name ?? "").trim();
    const phone = String(user.user_metadata?.phone ?? "").trim();
    const email = String(user.email ?? "").trim().toLowerCase();
    if (!token || !fullName || !phone || !email) return response({ error: "This identity was not created through FrostTech Guest registration." }, 403, origin);

    const { data: profile, error: profileError } = await admin.from("profiles").select("id").eq("id", user.id).maybeSingle();
    if (profileError) throw profileError;
    if (profile) return response({ error: "This identity already has a customer profile. Please use Customer Sign In." }, 403, origin);

    const tokenHash = await sha256(token);
    const { data: intent, error: intentError } = await admin.schema("private")
      .from("guest_registration_intents")
      .select("id, email, full_name, phone")
      .eq("registration_token_hash", tokenHash)
      .eq("email", email)
      .is("used_at", null)
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    if (intentError) throw intentError;
    if (!intent || intent.full_name !== fullName || intent.phone !== phone) return response({ error: "The Guest registration proof is invalid or expired. Please register again." }, 403, origin);

    const { error: updateError } = await admin.auth.admin.updateUserById(user.id, {
      app_metadata: { ...(user.app_metadata ?? {}), account_type: "guest" },
      user_metadata: { full_name: fullName, phone, account_type: "guest" },
    });
    if (updateError) throw updateError;

    const { data: consumed, error: consumeError } = await admin.schema("private")
      .from("guest_registration_intents")
      .update({ used_at: new Date().toISOString(), auth_user_id: user.id })
      .eq("id", intent.id)
      .is("used_at", null)
      .select("id")
      .maybeSingle();
    if (consumeError) throw consumeError;
    if (!consumed) {
      const { data: refreshed, error: refreshError } = await admin.auth.admin.getUserById(user.id);
      if (refreshError || refreshed.user?.app_metadata?.account_type !== "guest") return response({ error: "Guest registration proof has already been used. Please contact FrostTech support." }, 403, origin);
    }
    return response({ ok: true, identity: "guest" }, 200, origin);
  } catch (error) {
    console.error("Guest activation failed:", error);
    return response({ error: "Guest verification could not be completed. Please try again." }, 500, origin);
  }
});