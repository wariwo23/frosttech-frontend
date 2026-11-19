import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGIN = "https://wariwo23.github.io";

const corsHeaders = {
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function reply(body: Record<string, unknown>, status = 200, origin: string | null = null) {
  const allowed = !origin || origin === ALLOWED_ORIGIN;
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin": allowed ? (origin || ALLOWED_ORIGIN) : "null",
      "Content-Type": "application/json",
    },
  });
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function moneyToKobo(value: unknown, field: string): number {
  const amount = typeof value === "number" ? value : Number(value ?? 0);
  if (!Number.isFinite(amount) || amount < 0 || amount > 1_000_000_000) {
    throw new Error(`Invalid ${field} amount.`);
  }
  const kobo = Math.round(amount * 100);
  if (!Number.isSafeInteger(kobo)) throw new Error(`Invalid ${field} amount.`);
  return kobo;
}

function text(value: unknown, max: number, field: string, required = false): string {
  const result = String(value ?? "").trim();
  if (required && !result) throw new Error(`${field} is required.`);
  if (result.length > max) throw new Error(`${field} is too long.`);
  return result;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin":
        !origin || origin === ALLOWED_ORIGIN ? (origin || ALLOWED_ORIGIN) : "null",
    }});
  }
  if (req.method !== "POST") return reply({ error: "POST requests only." }, 405, origin);
  if (origin && origin !== ALLOWED_ORIGIN) return reply({ error: "Origin not allowed." }, 403, origin);

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error("Direct quotation function configuration is incomplete.");
    return reply({ error: "The quotation service is not configured." }, 500, origin);
  }

  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return reply({ error: "Please sign in as an authorised FrostTech operator." }, 401, origin);
    }

    const token = authorization.slice(7);
    const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await caller.auth.getUser(token);
    if (userError || !userData.user) {
      return reply({ error: "Your session is invalid or expired. Please sign in again." }, 401, origin);
    }

    // Reuse FrostTech's existing server-verified department role function.
    const { data: role, error: roleError } = await caller.rpc("admin_get_my_role");
    if (roleError || !["super_admin", "operations_admin"].includes(String(role))) {
      return reply({ error: "Super Administrator or Operations Administrator access is required to prepare quotations." }, 403, origin);
    }

    const raw = await req.text();
    if (raw.length > 64 * 1024) return reply({ error: "Request is too large." }, 413, origin);
    const body = JSON.parse(raw);
    const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    if (body.action === "list_drafts") {
      const { data: drafts, error: listError } = await db
        .from("frosttech_direct_quotations")
        .select("id, quotation_number, customer_name, customer_email, subtotal, additional_charges, discount, delivery_cost, total_amount, status, created_at, validity_expires_at")
        .eq("created_by", userData.user.id)
        .eq("status", "draft")
        .order("created_at", { ascending: false })
        .limit(100);
      if (listError) {
        console.error("Direct quotation draft list failed:", listError);
        return reply({ error: "Could not load your saved quotation drafts." }, 500, origin);
      }
      return reply({ success: true, drafts: drafts || [] }, 200, origin);
    }

    if (body.action === "get_draft") {
      if (!isUuid(body.quotation_id)) return reply({ error: "A valid quotation ID is required." }, 400, origin);
      const { data: draft, error: draftError } = await db
        .from("frosttech_direct_quotations")
        .select("id,quotation_number,customer_id,customer_name,customer_email,customer_phone,subtotal,additional_charges,discount,delivery_cost,total_amount,validity_expires_at,customer_message,internal_note,status")
        .eq("id", body.quotation_id).eq("created_by", userData.user.id).eq("status", "draft").maybeSingle();
      if (draftError || !draft) return reply({ error: "Only your own saved draft can be opened for editing." }, 404, origin);
      const { data: items, error: itemError } = await db
        .from("frosttech_direct_quotation_items")
        .select("item_type,product_id,description,quantity,unit,unit_price,line_total")
        .eq("direct_quotation_id", draft.id).order("line_number");
      if (itemError || !items?.length) return reply({ error: "The saved draft items could not be loaded." }, 409, origin);
      return reply({ success: true, quotation: draft, items }, 200, origin);
    }

    if (!["create_draft", "update_draft"].includes(String(body.action))) {
      return reply({ error: "Unsupported action." }, 400, origin);
    }
    if (body.action === "update_draft" && !isUuid(body.quotation_id)) {
      return reply({ error: "A valid quotation ID is required to update a draft." }, 400, origin);
    }

    const customerName = text(body.customer_name, 160, "Customer name", true);
    const customerEmail = text(body.customer_email, 254, "Customer email", true).toLowerCase();
    const customerPhone = text(body.customer_phone, 40, "Customer phone");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(customerEmail)) {
      return reply({ error: "Enter a valid customer email address." }, 400, origin);
    }
    if (!Array.isArray(body.items) || body.items.length < 1 || body.items.length > 100) {
      return reply({ error: "Add between 1 and 100 quotation items." }, 400, origin);
    }

    let customerId: string | null = null;
    if (body.customer_id !== undefined && body.customer_id !== null && body.customer_id !== "") {
      if (!isUuid(body.customer_id)) return reply({ error: "Invalid registered customer selection." }, 400, origin);
      const { data: customer, error } = await db
        .from("customers")
        .select("id, email, full_name")
        .eq("id", body.customer_id)
        .maybeSingle();
      if (error || !customer) return reply({ error: "The selected customer account could not be verified." }, 409, origin);
      if (String(customer.email ?? "").trim().toLowerCase() !== customerEmail) {
        return reply({ error: "The quotation email must match the selected customer's registered email." }, 409, origin);
      }
      customerId = customer.id;
    }

    if (!customerId) {
      const { data: matchingCustomers, error: matchError } = await db
        .from("customers")
        .select("id,email")
        .eq("email", customerEmail)
        .limit(2);
      if (matchError) {
        console.error("Existing customer email lookup failed:", matchError);
        return reply({ error: "Could not verify whether this email belongs to an existing FrostTech customer." }, 500, origin);
      }
      if ((matchingCustomers || []).length > 1) {
        return reply({ error: "More than one customer record uses this email. Please ask an administrator to reconcile the customer records." }, 409, origin);
      }
      if (matchingCustomers?.length === 1) customerId = matchingCustomers[0].id;
    }

    const normalizedItems: Record<string, unknown>[] = [];
    let subtotalKobo = 0;

    for (let i = 0; i < body.items.length; i++) {
      const item = body.items[i];
      if (!item || typeof item !== "object") return reply({ error: `Quotation item ${i + 1} is invalid.` }, 400, origin);
      const itemType = String(item.item_type ?? "").toLowerCase();
      if (!["product", "service", "accessory", "installation", "other"].includes(itemType)) {
        return reply({ error: `Quotation item ${i + 1} has an unsupported type.` }, 400, origin);
      }
      const description = text(item.description, 500, `Item ${i + 1} description`, true);
      const unit = text(item.unit || "unit", 40, `Item ${i + 1} unit`, true);
      const quantity = Number(item.quantity);
      if (!Number.isFinite(quantity) || quantity <= 0 || quantity > 1_000_000) {
        return reply({ error: `Item ${i + 1} quantity is invalid.` }, 400, origin);
      }
      const quantityMilli = Math.round(quantity * 1000);
      if (!Number.isSafeInteger(quantityMilli) || quantityMilli <= 0) {
        return reply({ error: `Item ${i + 1} quantity precision is invalid.` }, 400, origin);
      }

      let productId: string | null = null;
      if (itemType === "product") {
        if (!isUuid(item.product_id)) return reply({ error: `Item ${i + 1} must reference a valid catalogue product.` }, 400, origin);
        const { data: product, error } = await db
          .from("products")
          .select("id, name, unit, is_active")
          .eq("id", item.product_id)
          .maybeSingle();
        if (error || !product || product.is_active !== true) {
          return reply({ error: `Catalogue product for item ${i + 1} is unavailable.` }, 409, origin);
        }
        productId = product.id;
      } else if (item.product_id) {
        return reply({ error: `Non-product item ${i + 1} cannot reference a catalogue product.` }, 400, origin);
      }

      const unitPriceKobo = moneyToKobo(item.unit_price, `Item ${i + 1} unit price`);
      const lineTotalKobo = Math.round((quantityMilli * unitPriceKobo) / 1000);
      if (!Number.isSafeInteger(lineTotalKobo)) return reply({ error: `Item ${i + 1} total is invalid.` }, 400, origin);
      subtotalKobo += lineTotalKobo;
      if (!Number.isSafeInteger(subtotalKobo)) return reply({ error: "Quotation subtotal is too large." }, 400, origin);

      normalizedItems.push({
        line_number: i + 1,
        item_type: itemType,
        product_id: productId,
        description,
        quantity: quantityMilli / 1000,
        unit,
        unit_price: unitPriceKobo / 100,
        line_total: lineTotalKobo / 100,
      });
    }

    const additionalKobo = moneyToKobo(body.additional_charges, "Additional charges");
    const discountKobo = moneyToKobo(body.discount, "Discount");
    const deliveryKobo = moneyToKobo(body.delivery_cost, "Delivery");
    if (discountKobo > subtotalKobo + additionalKobo) {
      return reply({ error: "Discount cannot exceed the subtotal plus additional charges." }, 400, origin);
    }

    const totalKobo = subtotalKobo + additionalKobo - discountKobo + deliveryKobo;
    if (!Number.isSafeInteger(totalKobo) || totalKobo < 0) {
      return reply({ error: "Quotation total is invalid." }, 400, origin);
    }

    const isUpdate = body.action === "update_draft";
    const rpcName = isUpdate ? "frosttech_update_direct_quotation_draft" : "frosttech_create_direct_quotation_draft";
    const rpcArgs: Record<string, unknown> = {
      p_header: {
        customer_id: customerId,
        customer_name: customerName,
        customer_email: customerEmail,
        customer_phone: customerPhone || null,
        subtotal: subtotalKobo / 100,
        additional_charges: additionalKobo / 100,
        discount: discountKobo / 100,
        delivery_cost: deliveryKobo / 100,
        validity_expires_at: body.validity_expires_at || null,
        customer_message: text(body.customer_message, 4000, "Customer message"),
        internal_note: text(body.internal_note, 4000, "Internal note"),
      },
      p_items: normalizedItems,
      p_actor: userData.user.id,
    };
    if (isUpdate) rpcArgs.p_quote_id = body.quotation_id;
    const { data: created, error: createError } = await db.rpc(rpcName, rpcArgs);

    if (createError || !created) {
      console.error("Atomic direct quotation draft save failed:", createError);
      return reply({ error: "The quotation draft could not be saved. It may have been issued or changed in another session." }, 409, origin);
    }

    return reply({
      success: true,
      message: isUpdate ? "Quotation draft updated. It remains private and has not been issued." : "Direct quotation draft saved. It has not been sent to the customer and no payment has been started.",
      quotation: created,
      item_count: created.item_count,
    }, isUpdate ? 200 : 201, origin);
  } catch (error) {
    console.error("Create direct quotation error:", error);
    return reply({ error: error instanceof Error ? error.message : "Unexpected quotation error." }, 400, origin);
  }
});
