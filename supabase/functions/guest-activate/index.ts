import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGIN = "https://wariwo23.github.io";

function response(body: Record<string, unknown>, status = 200, origin: string | null = null) {
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

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: {
    "Access-Control-Allow-Origin": origin === ALLOWED_ORIGIN ? origin : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  }});
  if (req.method !== "POST") return response({ error: "Method not allowed." }, 405, origin);
  if (origin && origin !== ALLOWED_ORIGIN) return response({ error: "Origin not allowed." }, 403, origin);

  const authorization = req.headers.get("Authorization") ?? "";
  const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return response({ error: "A valid guest session is required." }, 401, origin);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return response({ error: "Guest verification service is not configured." }, 500, origin);
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const { data: userData, error: userError } = await userClient.auth.getUser(tokenMatch[1]);
    const user = userData.user;
    if (userError || !user) return response({ error: "Guest session is invalid or expired." }, 401, origin);
    if (!user.email_confirmed_at) return response({ error: "Confirm your email address before continuing." }, 403, origin);
    if (user.user_metadata?.account_type !== "guest") {
      return response({ error: "This identity was not registered through FrostTech Guest registration." }, 403, origin);
    }
    const fullName = String(user.user_metadata?.full_name ?? "").trim();
    const phone = String(user.user_metadata?.phone ?? "").trim();
    if (!fullName || !phone || !user.email) {
      return response({ error: "Guest registration details are incomplete. Please contact FrostTech support." }, 400, origin);
    }

    // A guest identity must never be attached to a registered customer profile.
    const { data: profile, error: profileError } = await admin
      .from("profiles").select("id").eq("id", user.id).maybeSingle();
    if (profileError) throw profileError;
    if (profile) return response({ error: "This identity already has a FrostTech customer profile. Please use Customer Sign In." }, 403, origin);

    const trustedMetadata = { ...(user.app_metadata ?? {}), account_type: "guest" };
    const { error: updateError } = await admin.auth.admin.updateUserById(user.id, {
      app_metadata: trustedMetadata,
    });
    if (updateError) throw updateError;

    return response({ ok: true, identity: "guest" }, 200, origin);
  } catch (error) {
    console.error("Guest activation failed:", error);
    return response({ error: "Guest verification could not be completed. Please try again." }, 500, origin);
  }
});