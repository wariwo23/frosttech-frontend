import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

async function hmac(value: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return Array.from(new Uint8Array(signature))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return respond({ error: "POST requests only." }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return respond({ error: "Guest alternative service is not configured." }, 500);

    const body = await request.json().catch(() => null);
    if (!body || typeof body !== "object") return respond({ error: "Invalid request." }, 400);

    const action = typeof body.action === "string" ? body.action : "decide";
    const quotationNumber = typeof body.quotation_number === "string" ? body.quotation_number.trim() : "";
    if (!quotationNumber || quotationNumber.length > 80) {
      return respond({ error: "A valid guest quotation reference is required." }, 400);
    }

    const authorization = request.headers.get("Authorization") || "";
    const rawToken = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
    if (!rawToken || rawToken.length > 200) {
      return respond({ error: "Verify your email before accessing alternatives." }, 401);
    }

    const db = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: quotation, error: quotationError } = await db
      .from("admin_quotations")
      .select("id,request_id,customer_id")
      .eq("quotation_number", quotationNumber)
      .maybeSingle();

    if (quotationError || !quotation || quotation.customer_id !== null) {
      return respond({ error: "The guest quotation could not be verified." }, 404);
    }

    const { data: customerRequest, error: requestError } = await db
      .from("quote_requests")
      .select("id,customer_id,admin_fee_status,admin_fee_paid_at")
      .eq("id", quotation.request_id)
      .maybeSingle();

    if (requestError || !customerRequest || customerRequest.customer_id !== null) {
      return respond({ error: "The guest customer request could not be verified." }, 404);
    }

    const { data: access, error: accessError } = await db
      .from("guest_quotation_access")
      .select("email_normalized,access_token_hash,access_expires_at")
      .eq("request_id", customerRequest.id)
      .maybeSingle();

    if (accessError || !access?.email_normalized || !access.access_token_hash ||
        !access.access_expires_at || new Date(access.access_expires_at).getTime() <= Date.now()) {
      return respond({ error: "Guest access has expired. Verify your email again." }, 401);
    }

    const candidate = await hmac("token:" + customerRequest.id + ":" + rawToken, serviceKey);
    if (!constantTimeEqual(candidate, access.access_token_hash)) {
      return respond({ error: "Guest access could not be verified." }, 401);
    }

    if (String(customerRequest.admin_fee_status || "").toLowerCase() !== "paid" ||
        !customerRequest.admin_fee_paid_at) {
      return respond({
        error: "Verify the quotation processing and marketplace administration fee before viewing or deciding on alternatives."
      }, 403);
    }

    if (action === "get_alternatives") {
      const [snapshotResult, proposalResult, decisionResult] = await Promise.all([
        db.from("quote_request_original_snapshots")
          .select("original_payload,capture_type")
          .eq("request_id", customerRequest.id)
          .maybeSingle(),
        db.from("alternative_proposals")
          .select("id,proposer_type,version_number,reason,proposed_payload,commercial_terms,differences,submitted_at")
          .eq("request_id", customerRequest.id)
          .order("submitted_at", { ascending: false }),
        db.from("alternative_proposal_decisions")
          .select("proposal_id,decision,decision_reason,decided_at")
          .eq("request_id", customerRequest.id),
      ]);

      if (snapshotResult.error || proposalResult.error || decisionResult.error) {
        console.error("Guest alternatives lookup failed.");
        return respond({ error: "Unable to load alternative proposals." }, 500);
      }

      return respond({
        success: true,
        snapshot: snapshotResult.data || null,
        proposals: proposalResult.data || [],
        decisions: decisionResult.data || [],
      });
    }

    if (action !== "decide") return respond({ error: "Unsupported guest alternative action." }, 400);

    const proposalId = typeof body.proposal_id === "string" ? body.proposal_id.trim() : "";
    const decision = typeof body.decision === "string" ? body.decision.trim().toLowerCase() : "";
    const reason = typeof body.reason === "string" ? body.reason.trim() : "";

    if (!/^[0-9a-f-]{36}$/i.test(proposalId) ||
        !["accepted", "rejected"].includes(decision) || reason.length > 1000) {
      return respond({ error: "The proposal decision details are invalid." }, 400);
    }

    const { data: decisionId, error: decisionError } = await db.rpc(
      "frosttech_decide_alternative_proposal_guest_v1",
      {
        p_proposal_id: proposalId,
        p_decision: decision,
        p_decision_reason: reason || null,
        p_guest_email_normalized: access.email_normalized,
      },
    );

    if (decisionError || !decisionId) {
      console.error("Guest alternative decision failed:", decisionError?.message);
      return respond({
        error: decisionError?.message || "The alternative decision could not be recorded.",
      }, 409);
    }

    return respond({
      success: true,
      decision_id: decisionId,
      proposal_id: proposalId,
      decision,
      message: decision === "accepted"
        ? "Your acceptance of this alternative has been recorded."
        : "Your rejection of this alternative has been recorded.",
    });
  } catch (error) {
    console.error("Guest alternative service error:", error instanceof Error ? error.message : "Unknown error");
    return respond({ error: "An unexpected error occurred." }, 500);
  }
});