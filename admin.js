/* =========================================================
   FROSTTECH ADMIN
   admin.js
   ========================================================= */

/* =========================================================
   SUPABASE SETUP
   ========================================================= */

const SUPABASE_URL =
  "https://nftxptjpgidcsgtaltjn.supabase.co";

const SUPABASE_KEY =
  "sb_publishable_9b9QzhXqSJflCKDUc2sQnA_p4f0pblV";

const supabaseClient =
  window.supabase.createClient(
    SUPABASE_URL,
    SUPABASE_KEY
  );


/* =========================================================
   DOM HELPERS
   ========================================================= */

function $(id) {
  return document.getElementById(id);
}

function show(id) {
  const el = $(id);
  if (el) el.style.display = "";
}

function hide(id) {
  const el = $(id);
  if (el) el.style.display = "none";
}


/* =========================================================
   MESSAGE DISPLAY
   ========================================================= */

function showMessage(message, type = "success") {

  const box = $("message");

  if (!box) {
    alert(message);
    return;
  }

  box.textContent = message;
  box.className = "message message-" + type;
  box.style.display = "block";
}


/* =========================================================
   SYSTEM STATUS
   ========================================================= */

function setSystemStatus(message, type = "success") {

  const box = $("systemStatus");

  if (!box) return;

  box.textContent = message;
  box.className = "status status-" + type;
}


/* =========================================================
   LOGIN
   ========================================================= */

async function loginAdmin() {

  const email = $("email")?.value.trim();
  const password = $("password")?.value;

  if (!email || !password) {
    showMessage(
      "Please enter your email and password.",
      "error"
    );
    return;
  }

  const button = $("loginBtn");

  if (button) {
    button.disabled = true;
    button.textContent = "Logging in...";
  }

  try {

    const { data, error } =
      await supabaseClient.auth.signInWithPassword({
        email: email,
        password: password
      });

    if (error) {
      throw error;
    }

    if (!data.user) {
      throw new Error("Login was not completed.");
    }

    await checkAdminProfile(data.user);

  } catch (error) {

    console.error("Login error:", error);

    showMessage(
      "Login failed: " + error.message,
      "error"
    );

  } finally {

    if (button) {
      button.disabled = false;
      button.textContent = "Login";
    }
  }
}


/* =========================================================
   ADMIN PROFILE CHECK
   ========================================================= */

async function checkAdminProfile(user) {

  try {

    const { data, error } =
      await supabaseClient
        .from("profiles")
        .select("id, email, full_name, role, is_active")
        .eq("id", user.id)
        .single();

    if (error) {
      throw error;
    }

    if (!data) {
      throw new Error("Admin profile not found.");
    }

    if (data.role !== "admin") {
      await supabaseClient.auth.signOut();
      throw new Error("This account is not an administrator.");
    }

    if (data.is_active !== true) {
      await supabaseClient.auth.signOut();
      throw new Error("This administrator account is inactive.");
    }

    showAdminDashboard(data);

  } catch (error) {

    console.error("Profile check error:", error);

    showMessage(
      "Admin verification failed: " + error.message,
      "error"
    );
  }
}


/* =========================================================
   SHOW ADMIN DASHBOARD
   ========================================================= */

function showAdminDashboard(profile) {

  hide("loginSection");
  show("dashboard");

  const userDisplay = $("loggedUser");

  if (userDisplay) {

    userDisplay.textContent =
      profile.email ||
      profile.full_name ||
      "Administrator";
  }

  setSystemStatus(
    "Supabase connection initialized successfully.",
    "success"
  );

  loadQuoteRequests();
  loadSupplierQuotes();
}


/* =========================================================
   LOGOUT
   ========================================================= */

async function logoutAdmin() {

  try {

    const { error } =
      await supabaseClient.auth.signOut();

    if (error) {
      throw error;
    }

    hide("dashboard");
    show("loginSection");

    const email = $("email");
    const password = $("password");

    if (email) email.value = "";
    if (password) password.value = "";

    showMessage(
      "You have been logged out.",
      "success"
    );

  } catch (error) {

    console.error("Logout error:", error);

    showMessage(
      "Logout failed: " + error.message,
      "error"
    );
  }
}


/* =========================================================
   SESSION CHECK
   ========================================================= */

async function checkSession() {

  try {

    const {
      data: { session },
      error
    } = await supabaseClient.auth.getSession();

    if (error) {
      throw error;
    }

    if (!session || !session.user) {

      hide("dashboard");
      show("loginSection");

      setSystemStatus(
        "Please log in as administrator.",
        "warning"
      );

      return;
    }

    await checkAdminProfile(session.user);

  } catch (error) {

    console.error("Session error:", error);

    hide("dashboard");
    show("loginSection");

    setSystemStatus(
      "Unable to check login session.",
      "error"
    );
  }
}


/* =========================================================
   CUSTOMER QUOTE REQUESTS
   ========================================================= */

async function loadQuoteRequests() {

  const container = $("quoteRequests");

  if (!container) return;

  container.innerHTML =
    '<div class="loading">Loading quote requests...</div>';

  try {

    const { data, error } =
      await supabaseClient
        .from("quote_requests")
        .select("*")
        .order("created_at", {
          ascending: false
        });

    if (error) {
      throw error;
    }

    if (!data || data.length === 0) {

      container.innerHTML =
        '<div class="empty-state">No customer quote requests found.</div>';

      return;
    }

    container.innerHTML = "";

    data.forEach(request => {

      const card =
        document.createElement("div");

      card.className =
        "card quote-card";

      const requestNumber =
        request.request_number ||
        request.request_no ||
        request.id;

      const customer =
        request.customer_name ||
        request.full_name ||
        request.name ||
        "N/A";

      const phone =
        request.phone ||
        request.customer_phone ||
        "N/A";

      const product =
        request.product_name ||
        request.product ||
        "N/A";

      const quantity =
        request.quantity || 1;

      const address =
        request.delivery_address ||
        request.address ||
        "N/A";

      const status =
        request.status ||
        "pending";

      card.innerHTML = `
        <div class="request-number">
          Request ${escapeHtml(requestNumber)}
        </div>

        <p>
          <strong>Status:</strong>
          <span class="badge badge-${escapeHtml(status)}">
            ${escapeHtml(status)}
          </span>
        </p>

        <p>
          <strong>Customer:</strong>
          ${escapeHtml(customer)}
        </p>

        <p>
          <strong>Phone:</strong>
          ${escapeHtml(phone)}
        </p>

        <p>
          <strong>Product:</strong>
          ${escapeHtml(product)}
        </p>

        <p>
          <strong>Quantity:</strong>
          ${escapeHtml(quantity)}
        </p>

        <p>
          <strong>Delivery Address:</strong>
          ${escapeHtml(address)}
        </p>

        <label>Status</label>

        <select
          id="request-status-${request.id}">
          <option value="pending"
            ${status === "pending" ? "selected" : ""}>
            Pending
          </option>

          <option value="reviewing"
            ${status === "reviewing" ? "selected" : ""}>
            Reviewing
          </option>

          <option value="quoted"
            ${status === "quoted" ? "selected" : ""}>
            Quoted
          </option>

          <option value="completed"
            ${status === "completed" ? "selected" : ""}>
            Completed
          </option>

          <option value="cancelled"
            ${status === "cancelled" ? "selected" : ""}>
            Cancelled
          </option>
        </select>

        <button
          class="btn-primary"
          onclick="updateRequestStatus('${request.id}')">
          Save Status
        </button>
      `;

      container.appendChild(card);
    });

  } catch (error) {

    console.error(
      "Quote request error:",
      error
    );

    container.innerHTML = `
      <div class="message message-error">
        Unable to load quote requests:
        ${escapeHtml(error.message)}
      </div>
    `;
  }
}


/* =========================================================
   UPDATE CUSTOMER REQUEST STATUS
   ========================================================= */

async function updateRequestStatus(requestId) {

  const select =
    $("request-status-" + requestId);

  if (!select) return;

  const newStatus =
    select.value;

  try {

    const { error } =
      await supabaseClient
        .from("quote_requests")
        .update({
          status: newStatus,
          updated_at: new Date().toISOString()
        })
        .eq("id", requestId);

    if (error) {
      throw error;
    }

    showMessage(
      "Customer request status updated.",
      "success"
    );

    await loadQuoteRequests();

  } catch (error) {

    console.error(
      "Status update error:",
      error
    );

    showMessage(
      "Unable to update status: " +
      error.message,
      "error"
    );
  }
}


/* =========================================================
   SUPPLIER QUOTATIONS
   ========================================================= */

async function loadSupplierQuotes() {

  const container =
    $("supplierQuotes");

  if (!container) return;

  container.innerHTML =
    '<div class="loading">Loading supplier quotations...</div>';

  try {

    const { data, error } =
      await supabaseClient
        .from("supplier_quotes")
        .select("*")
        .order("created_at", {
          ascending: false
        });

    if (error) {
      throw error;
    }

    if (!data || data.length === 0) {

      container.innerHTML =
        '<div class="empty-state">No supplier quotations found.</div>';

      return;
    }

    container.innerHTML = "";

    data.forEach(quote => {

      const card =
        document.createElement("div");

      card.className =
        "card supplier-quote-card";

      const supplierPrice =
        Number(
          quote.supplier_total || 0
        );

      const delivery =
        Number(
          quote.delivery_cost || 0
        );

      const margin =
        Number(
          quote.frosttech_margin_amount || 0
        );

      const customerTotal =
        Number(
          quote.customer_total ||
          supplierPrice +
          delivery +
          margin
        );

      const status =
        quote.status || "draft";

      card.innerHTML = `
        <h3>Supplier Quotation</h3>

        <p>
          <strong>Quote ID:</strong>
          ${escapeHtml(quote.id)}
        </p>

        <p>
          <strong>Request ID:</strong>
          ${escapeHtml(quote.request_id || "N/A")}
        </p>

        <p>
          <strong>Supplier ID:</strong>
          ${escapeHtml(quote.supplier_id || "N/A")}
        </p>

        <p>
          <strong>Product ID:</strong>
          ${escapeHtml(quote.product_id || "N/A")}
        </p>

        <p>
          <strong>Quantity:</strong>
          ${escapeHtml(quote.quantity || 1)}
        </p>

        <div class="price-box">

          <div class="price-row">
            <span>Supplier Total</span>
            <strong>
              ₦${supplierPrice.toLocaleString()}
            </strong>
          </div>

          <div class="price-row">
            <span>Delivery Cost</span>
            <strong>
              ₦${delivery.toLocaleString()}
            </strong>
          </div>

          <div class="price-row">
            <span>FrostTech Margin</span>
            <strong>
              ₦${margin.toLocaleString()}
            </strong>
          </div>

          <div class="price-row">
            <span>Customer Total</span>
            <strong class="customer-total">
              ₦${customerTotal.toLocaleString()}
            </strong>
          </div>

        </div>

        <p>
          <strong>Status:</strong>
          <span class="badge badge-${escapeHtml(status)}">
            ${escapeHtml(status)}
          </span>
        </p>

        <label>Supplier Quote Status</label>

        <select
          id="supplier-status-${quote.id}">

          <option value="draft"
            ${status === "draft" ? "selected" : ""}>
            Draft
          </option>

          <option value="submitted"
            ${status === "submitted" ? "selected" : ""}>
            Submitted
          </option>

          <option value="selected"
            ${status === "selected" ? "selected" : ""}>
            Selected
          </option>

          <option value="rejected"
            ${status === "rejected" ? "selected" : ""}>
            Rejected
          </option>

          <option value="expired"
            ${status === "expired" ? "selected" : ""}>
            Expired
          </option>

        </select>

        <button
          class="btn-success"
          onclick="updateSupplierQuoteStatus('${quote.id}')">
          Save Quote Status
        </button>

        ${
          status === "submitted"
          ? `
            <button
              class="btn-primary"
              onclick="selectSupplierQuote('${quote.id}')">
              Select This Supplier Quote
            </button>
          `
          : ""
        }
      `;

      container.appendChild(card);
    });

  } catch (error) {

    console.error(
      "Supplier quote error:",
      error
    );

    container.innerHTML = `
      <div class="message message-error">
        Unable to load supplier quotations:
        ${escapeHtml(error.message)}
      </div>
    `;
  }
}


/* =========================================================
   UPDATE SUPPLIER QUOTE STATUS
   ========================================================= */

async function updateSupplierQuoteStatus(
  quoteId
) {

  const select =
    $("supplier-status-" + quoteId);

  if (!select) return;

  const newStatus =
    select.value;

  try {

    const { error } =
      await supabaseClient
        .from("supplier_quotes")
        .update({
          status: newStatus,
          updated_at: new Date().toISOString()
        })
        .eq("id", quoteId);

    if (error) {
      throw error;
    }

    showMessage(
      "Supplier quotation status updated.",
      "success"
    );

    await loadSupplierQuotes();

  } catch (error) {

    console.error(
      "Supplier status error:",
      error
    );

    showMessage(
      "Unable to update supplier quote: " +
      error.message,
      "error"
    );
  }
}


/* =========================================================
   SELECT SUPPLIER QUOTE
   ========================================================= */

async function selectSupplierQuote(
  quoteId
) {

  const confirmed =
    confirm(
      "Select this supplier quotation?"
    );

  if (!confirmed) return;

  try {

    const { data: selectedQuote, error } =
      await supabaseClient
        .from("supplier_quotes")
        .select("*")
        .eq("id", quoteId)
        .single();

    if (error) {
      throw error;
    }

    if (!selectedQuote) {
      throw new Error(
        "Supplier quotation not found."
      );
    }

    /*
      First reject other quotations
      belonging to the same request.
    */

    const { error: rejectError } =
      await supabaseClient
        .from("supplier_quotes")
        .update({
          status: "rejected",
          updated_at:
            new Date().toISOString()
        })
        .eq(
          "request_id",
          selectedQuote.request_id
        )
        .neq("id", quoteId);

    if (rejectError) {
      throw rejectError;
    }

    /*
      Mark selected quotation.
    */

    const { error: selectError } =
      await supabaseClient
        .from("supplier_quotes")
        .update({
          status: "selected",
          customer_quote_status: "draft",
          updated_at:
            new Date().toISOString()
        })
        .eq("id", quoteId);

    if (selectError) {
      throw selectError;
    }

    showMessage(
      "Supplier quotation selected successfully.",
      "success"
    );

    await loadSupplierQuotes();

  } catch (error) {

    console.error(
      "Supplier selection error:",
      error
    );

    showMessage(
      "Unable to select supplier quotation: " +
      error.message,
      "error"
    );
  }
}


/* =========================================================
   REFRESH ALL DATA
   ========================================================= */

async function refreshAdminData() {

  await loadQuoteRequests();
  await loadSupplierQuotes();

  showMessage(
    "Admin data refreshed.",
    "success"
  );
}


/* =========================================================
   HTML ESCAPE
   ========================================================= */

function escapeHtml(value) {

  if (value === null ||
      value === undefined) {
    return "";
  }

  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}


/* =========================================================
   AUTH STATE LISTENER
   ========================================================= */

supabaseClient.auth.onAuthStateChange(
  async (event, session) => {

    console.log(
      "Auth event:",
      event
    );

    if (event === "SIGNED_OUT") {

      hide("dashboard");
      show("loginSection");

      return;
    }

    if (
      event === "SIGNED_IN" &&
      session &&
      session.user
    ) {

      await checkAdminProfile(
        session.user
      );
    }
  }
);


/* =========================================================
   BUTTON EVENTS
   ========================================================= */

document.addEventListener(
  "DOMContentLoaded",
  () => {

    const loginButton =
      $("loginBtn");

    if (loginButton) {

      loginButton.addEventListener(
        "click",
        loginAdmin
      );
    }

    const logoutButton =
      $("logoutBtn");

    if (logoutButton) {

      logoutButton.addEventListener(
        "click",
        logoutAdmin
      );
    }

    const refreshButton =
      $("refreshBtn");

    if (refreshButton) {

      refreshButton.addEventListener(
        "click",
        refreshAdminData
      );
    }

    checkSession();
  }
);
