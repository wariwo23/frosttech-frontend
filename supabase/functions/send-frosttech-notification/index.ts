import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const EMAIL_FROM = Deno.env.get("EMAIL_FROM") ?? "";
const NOTIFICATION_RECIPIENT =
  Deno.env.get("NOTIFICATION_RECIPIENT") ?? "";

const ALLOWED_ORIGIN = "https://wariwo23.github.io";
const MAX_BODY_BYTES = 16 * 1024;

const corsHeaders = {
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function cors(origin: string | null) {
  const allowed = !origin || origin === ALLOWED_ORIGIN;

  return {
    ...corsHeaders,
    "Access-Control-Allow-Origin":
      allowed ? (origin || "*") : "null",
    "Vary": "Origin",
  };
}

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
  origin: string | null = null,
) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...cors(origin),
      "Content-Type": "application/json",
    },
  });
}

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function isValidUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    .test(value);
}

function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function createAdminClient() {
  return createClient(
    SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    },
  );
}

async function updateEvent(
  admin: ReturnType<typeof createAdminClient>,
  eventKey: string,
  claimToken: string,
  values: Record<string, unknown>,
): Promise<boolean> {
  const { data, error } = await admin
    .from("email_notification_events")
    .update({
      ...values,
      claim_token: null,
    })
    .eq("event_key", eventKey)
    .eq("claim_token", claimToken)
    .eq("status", "sending")
    .select("id")
    .maybeSingle();

  if (error || !data) {
    console.error(
      "Notification event update failed or claim was lost:",
      error,
    );
    return false;
  }

  return true;
}

async function sendAndRecord(
  admin: ReturnType<typeof createAdminClient>,
  eventKey: string,
  eventType: string,
  recipient: string,
  payload: Record<string, unknown>,
  subject: string,
  html: string,
): Promise<boolean> {
  const { data: claimToken, error: claimError } =
    await admin.rpc("claim_frosttech_email_event_v2", {
      p_event_key: eventKey,
      p_event_type: eventType,
      p_recipient: recipient,
      p_payload: payload,
    });

  if (claimError) {
    console.error("Notification claim failed:", claimError);
    return false;
  }

  if (claimToken === null) {
    return true;
  }

  if (typeof claimToken !== "string" || !isValidUuid(claimToken)) {
    console.error("Invalid notification claim token.");
    return false;
  }

  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `frosttech:${eventKey}`,
      },
      body: JSON.stringify({
        from: EMAIL_FROM,
        to: [recipient],
        subject,
        html,
      }),
    });

    const result = await response.json().catch(() => ({}));

    if (!response.ok) {
      console.error("Resend rejected email:", result);
      await updateEvent(admin, eventKey, claimToken, {
        status: "failed",
        last_error: JSON.stringify({ http_status: response.status, provider_response: result }).slice(0, 2000),
        updated_at: new Date().toISOString(),
      });
      return false;
    }

    const recorded = await updateEvent(admin, eventKey, claimToken, {
      status: "sent",
      provider_message_id: result.id || null,
      sent_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      last_error: null,
    });

    if (!recorded) {
      console.error("Email accepted by Resend but event status was not updated.");
    }
    return true;
  } catch (error) {
    console.error("Email delivery error:", error);
    await updateEvent(admin, eventKey, claimToken, {
      status: "failed",
      last_error: JSON.stringify({ outcome: "unknown", error: String(error).slice(0, 1800) }),
      updated_at: new Date().toISOString(),
    });
    return false;
  }
}

function buildCustomerConfirmationEmail(
  requestNumber: string,
  customerName: string,
): string {
  return `
    <div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
      <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
      <p>Hello ${escapeHtml(customerName)},</p>
      <p>Your quotation request has been received successfully.</p>
      <p><strong>Request Number:</strong> ${escapeHtml(requestNumber)}</p>
      <p>Our team will review your request and contact you.</p>
      <p>Thank you for choosing FrostTech.</p>
    </div>
  `;
}

function buildEmail(
  eventType: string,
  p: Record<string, unknown>,
): string {
  if (eventType === "quote_request_submitted") {
    return `
      <div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
        <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
        <p>A customer has submitted a new quotation request.</p>
        <p><strong>Customer Name:</strong> ${escapeHtml(p.customer_name || "Not provided")}</p>
        <p><strong>Customer Email:</strong> ${escapeHtml(p.customer_email || "Not provided")}</p>
        <p><strong>Customer Phone:</strong> ${escapeHtml(p.customer_phone || "Not provided")}</p>
        <p><strong>Request Number:</strong> ${escapeHtml(p.request_number)}</p>
        <p>Please log in to the FrostTech Administration Dashboard to review the quotation.</p>
      </div>
    `;
  }

  return `
    <div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
      <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
      <p>A new advertiser application has been submitted.</p>
      <p>Please log in to the FrostTech Administration Dashboard to review the application.</p>
    </div>
  `;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: cors(origin),
    });
  }

  if (req.method !== "POST") {
    return jsonResponse(
      { error: "Method not allowed." },
      405,
      origin,
    );
  }

  if (origin && origin !== ALLOWED_ORIGIN) {
    return jsonResponse(
      { error: "Origin not allowed." },
      403,
      origin,
    );
  }

  if (
    !SUPABASE_URL ||
    !SUPABASE_ANON_KEY ||
    !SUPABASE_SERVICE_ROLE_KEY ||
    !RESEND_API_KEY ||
    !EMAIL_FROM ||
    !NOTIFICATION_RECIPIENT
  ) {
    return jsonResponse(
      { error: "Notification service is not configured." },
      500,
      origin,
    );
  }

  const contentLength = Number(
    req.headers.get("content-length") || "0",
  );

  if (
    Number.isFinite(contentLength) &&
    contentLength > MAX_BODY_BYTES
  ) {
    return jsonResponse(
      { error: "Request body is too large." },
      413,
      origin,
    );
  }

  let body: Record<string, unknown>;

  try {
    const rawBody = await req.text();

    if (
      new TextEncoder().encode(rawBody).byteLength >
      MAX_BODY_BYTES
    ) {
      return jsonResponse(
        { error: "Request body is too large." },
        413,
        origin,
      );
    }

    const parsed: unknown = JSON.parse(rawBody);

    if (
      !parsed ||
      typeof parsed !== "object" ||
      Array.isArray(parsed)
    ) {
      return jsonResponse(
        { error: "Invalid request body." },
        400,
        origin,
      );
    }

    body = parsed as Record<string, unknown>;
  } catch {
    return jsonResponse(
      { error: "Invalid request body." },
      400,
      origin,
    );
  }

  const admin = createAdminClient();

  try {
    /*
     * PUBLIC QUOTATION NOTIFICATION
     *
     * A website visitor does not need an account or login
     * to submit a quotation request.
     *
     * The request number is used only to locate the saved
     * quotation. Email details are retrieved from Supabase,
     * never trusted from the browser request.
     *
     * No quotation details are returned to the visitor.
     */
    if (body.event_type === "quote_request_submitted") {
      const requestNumber = String(
        body.request_number || "",
      ).trim();

      if (
        !requestNumber ||
        requestNumber.length > 128
      ) {
        return jsonResponse(
          { error: "Valid request number is required." },
          400,
          origin,
        );
      }

      const { data: quote, error } = await admin
        .from("quote_requests")
        .select(
          "id, request_number, customer_name, customer_phone, customer_email, title, description, quantity, preferred_brand, budget, delivery_address",
        )
        .eq("request_number", requestNumber)
        .maybeSingle();

      if (error || !quote) {
        console.error("Quotation lookup failed:", error);

        return jsonResponse(
          { error: "Saved quotation request not found." },
          404,
          origin,
        );
      }

      const payload = {
        request_number: quote.request_number,
        customer_name: quote.customer_name,
        customer_phone: quote.customer_phone,
        customer_email: quote.customer_email,
        title: quote.title,
        description: quote.description,
        quantity: quote.quantity,
        preferred_brand: quote.preferred_brand,
        budget: quote.budget,
        delivery_address: quote.delivery_address,
      };

      const adminSent = await sendAndRecord(
        admin,
        `quote_request:${quote.id}`,
        "quote_request_submitted",
        NOTIFICATION_RECIPIENT,
        payload,
        "New FrostTech Quotation Request",
        buildEmail("quote_request_submitted", payload),
      );

      const customerEmail = String(quote.customer_email || "").trim();
      let customerSent = false;

      if (isValidEmail(customerEmail)) {
        const customerPayload = {
          request_number: quote.request_number,
          customer_name: quote.customer_name,
        };

        customerSent = await sendAndRecord(
          admin,
          `quote_request_customer:${quote.id}`,
          "quote_request_submitted",
          customerEmail,
          customerPayload,
          `FrostTech – Quotation Request Received – ${quote.request_number}`,
          buildCustomerConfirmationEmail(
            quote.request_number,
            quote.customer_name,
          ),
        );
      } else {
        console.error("Customer confirmation skipped: saved customer email is missing or invalid.");
      }

      return jsonResponse(
        {
          ok: true,
          admin_notification_failed: !adminSent,
          customer_confirmation_failed: !customerSent,
          notification_failed: !adminSent || !customerSent,
        },
        200,
        origin,
      );
    }

    /*
     * AUTHENTICATED ADVERTISER NOTIFICATION
     *
     * Advertiser submissions still require a valid login.
     * The advertiser record must belong to that user.
     * The CAC document must belong to that advertiser.
     */
    if (
      body.event_type === "advertiser_application_submitted"
    ) {
      const authorization =
        req.headers.get("Authorization") ?? "";

      const bearerMatch = authorization.match(
        /^Bearer\s+(.+)$/i,
      );

      if (!bearerMatch || !bearerMatch[1].trim()) {
        return jsonResponse(
          { error: "Advertiser authentication required." },
          401,
          origin,
        );
      }

      const accessToken = bearerMatch[1].trim();

      const userClient = createClient(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        {
          auth: {
            persistSession: false,
            autoRefreshToken: false,
          },
        },
      );

      const {
        data: { user },
        error: authError,
      } = await userClient.auth.getUser(accessToken);

      if (authError || !user) {
        return jsonResponse(
          { error: "Invalid or expired advertiser session." },
          401,
          origin,
        );
      }

      const advertiserId = String(
        body.advertiser_id || "",
      ).trim();

      const documentId = String(
        body.document_id || "",
      ).trim();

      if (
        !isValidUuid(advertiserId) ||
        !isValidUuid(documentId)
      ) {
        return jsonResponse(
          {
            error:
              "Valid application and CAC document IDs are required.",
          },
          400,
          origin,
        );
      }

      const { data: advertiser, error: advertiserError } =
        await admin
          .from("advertisers")
          .select(
            "id, user_id, company_name, contact_person, email, phone, business_address, registration_number, verification_status",
          )
          .eq("id", advertiserId)
          .eq("user_id", user.id)
          .maybeSingle();

      if (advertiserError || !advertiser) {
        console.error(
          "Advertiser lookup failed:",
          advertiserError,
        );

        return jsonResponse(
          { error: "Advertiser application not found." },
          404,
          origin,
        );
      }

      const { data: document, error: documentError } =
        await admin
          .from("advertiser_documents")
          .select("id, advertiser_id, document_type, removed_at")
          .eq("id", documentId)
          .eq("advertiser_id", advertiser.id)
          .eq("document_type", "CAC_CERTIFICATE")
          .is("removed_at", null)
          .maybeSingle();

      if (documentError || !document) {
        console.error(
          "CAC document lookup failed:",
          documentError,
        );

        return jsonResponse(
          { error: "Saved CAC document record not found." },
          404,
          origin,
        );
      }

      const payload = {
        company_name: advertiser.company_name,
        contact_person: advertiser.contact_person,
        email: advertiser.email,
        phone: advertiser.phone,
        business_address: advertiser.business_address,
        registration_number: advertiser.registration_number,
      };

      const adminSent = await sendAndRecord(
        admin,
        `advertiser_application:${advertiser.id}`,
        "advertiser_application_submitted",
        NOTIFICATION_RECIPIENT,
        { application_id: advertiser.id },
        "New FrostTech Advertiser Application",
        buildEmail("advertiser_application_submitted", {}),
      );

      const advertiserEmail = String(advertiser.email || "").trim();
      let advertiserConfirmationSent = false;

      if (isValidEmail(advertiserEmail)) {
        advertiserConfirmationSent = await sendAndRecord(
          admin,
          `advertiser_application_confirmation:${advertiser.id}`,
          "advertiser_application_submitted",
          advertiserEmail,
          { application_id: advertiser.id },
          "FrostTech – Advertiser Application Received",
          `
            <div style="font-family:Arial,sans-serif;color:#172333;max-width:600px;margin:0 auto;line-height:1.6">
              <h2 style="color:#063b70">FrostTech HVAC and Refrigeration</h2>
              <p>Your advertiser application has been received successfully.</p>
              <p>Our team will review your submission and contact you regarding the next steps.</p>
              <p>Thank you for your interest in FrostTech.</p>
            </div>
          `,
        );
      } else {
        console.error("Advertiser confirmation skipped: saved advertiser email is missing or invalid.");
      }

      return jsonResponse(
        {
          ok: true,
          admin_notification_failed: !adminSent,
          advertiser_confirmation_failed: !advertiserConfirmationSent,
          notification_failed: !adminSent || !advertiserConfirmationSent,
        },
        200,
        origin,
      );
    }

    return jsonResponse(
      { error: "Unsupported notification event." },
      400,
      origin,
    );
  } catch (error) {
    console.error("Notification function error:", error);

    return jsonResponse(
      {
        ok: true,
        notification_failed: true,
      },
      200,
      origin,
    );
  }
});