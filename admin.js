const SUPABASE_URL="https://nftxptjpgidcsgtaltjn.supabase.co";
const SUPABASE_KEY="sb_publishable_9b9QzhXqSJflCKDUc2sQnA_p4f0pblV";

const sb=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY);

const $=id=>document.getElementById(id);

function show(id){
  const e=$(id);
  if(e)e.style.display="";
}

function hide(id){
  const e=$(id);
  if(e)e.style.display="none";
}

function message(txt,type="info"){
  const e=$("message");
  if(!e)return;
  e.textContent=txt;
  e.className="message "+type;
  e.style.display="block";
}

function status(txt,type="status-success"){
  const e=$("systemStatus");
  if(e){
    e.textContent=txt;
    e.className="status "+type;
  }
}

function showLogin(){
  show("loginSection");
  hide("dashboard");
}

function showDashboard(user,profile){
  hide("loginSection");
  show("dashboard");

  if($("loggedUser"))
    $("loggedUser").textContent=user.email||profile.full_name||"Administrator";

  loadQuoteRequests();
  loadSupplierQuotes();
}

async function verifyAdmin(user){
  const {data,error}=await sb
    .from("profiles")
    .select("id,full_name,role,is_active")
    .eq("id",user.id)
    .single();

  if(error)throw new Error("Admin verification failed: "+error.message);

  if(data.role!=="admin"||data.is_active!==true)
    throw new Error("Admin access denied.");

  return data;
}

async function loginAdmin(){
  const email=$("email").value.trim();
  const password=$("password").value;

  if(!email||!password){
    message("Enter your email and password.","error");
    return;
  }

  message("Signing in...","info");

  const {data,error}=await sb.auth.signInWithPassword({email,password});

  if(error){
    message("Login failed: "+error.message,"error");
    showLogin();
    return;
  }

  try{
    const profile=await verifyAdmin(data.user);
    message("Login successful.","success");
    showDashboard(data.user,profile);
  }catch(e){
    await sb.auth.signOut();
    message(e.message,"error");
    showLogin();
  }
}

async function logoutAdmin(){
  await sb.auth.signOut();
  showLogin();
  message("You have been logged out.","success");
}

async function checkSession(){
  showLogin();

  const {data}=await sb.auth.getSession();
  const session=data.session;

  if(!session){
    status("Supabase connection initialized successfully.","status-success");
    return;
  }

  try{
    const profile=await verifyAdmin(session.user);
    showDashboard(session.user,profile);
    status("Supabase connection initialized successfully.","status-success");
  }catch(e){
    await sb.auth.signOut();
    showLogin();
    message(e.message,"error");
  }
}

async function loadQuoteRequests(){
  const box=$("quoteRequests");
  if(!box)return;

  box.innerHTML='<div class="loading">Loading quote requests...</div>';

  const {data,error}=await sb
    .from("quote_requests")
    .select("*")
    .order("created_at",{ascending:false});

  if(error){
    box.innerHTML='<div class="message error">Error loading requests: '+escapeHtml(error.message)+'</div>';
    return;
  }

  if(!data||!data.length){
    box.innerHTML='<div class="empty">No quote requests found.</div>';
    return;
  }

  box.innerHTML=data.map(r=>`
    <div class="quote-card">
      <h3>Request ${escapeHtml(r.request_number||r.id)}</h3>
      <p><strong>Status:</strong> ${escapeHtml(r.status||"pending")}</p>
      <p><strong>Quantity:</strong> ${escapeHtml(r.quantity||"1")}</p>
      <p><strong>Delivery:</strong> ${escapeHtml(r.delivery_address||"N/A")}</p>
      <label>Change Status</label>
      <select id="req_${r.id}">
        ${["pending","reviewing","quoted","accepted","rejected","completed"].map(s=>
          `<option value="${s}" ${r.status===s?"selected":""}>${s}</option>`
        ).join("")}
      </select>
      <button class="btn-primary" onclick="updateRequestStatus('${r.id}')">Save Status</button>
    </div>
  `).join("");
}

async function updateRequestStatus(id){
  const select=$("req_"+id);
  if(!select)return;

  const {error}=await sb
    .from("quote_requests")
    .update({status:select.value})
    .eq("id",id);

  if(error){
    message("Status update failed: "+error.message,"error");
    return;
  }

  message("Request status updated.","success");
  loadQuoteRequests();
}

async function loadSupplierQuotes(){
  const box=$("supplierQuotes");
  if(!box)return;

  box.innerHTML='<div class="loading">Loading supplier quotations...</div>';

  const {data,error}=await sb
    .from("supplier_quotes")
    .select("*")
    .order("created_at",{ascending:false});

  if(error){
    box.innerHTML='<div class="message error">Error loading supplier quotations: '+escapeHtml(error.message)+'</div>';
    return;
  }

  if(!data||!data.length){
    box.innerHTML='<div class="empty">No supplier quotations found.</div>';
    return;
  }

  box.innerHTML=data.map(q=>`
    <div class="supplier-quote-card">
      <h3>Supplier Quotation</h3>
      <p><strong>Supplier:</strong> ${escapeHtml(q.supplier_id||"N/A")}</p>
      <p><strong>Product:</strong> ${escapeHtml(q.product_id||"N/A")}</p>
      <p><strong>Quantity:</strong> ${escapeHtml(q.quantity||1)}</p>
      <p><strong>Supplier Total:</strong> ₦${Number(q.supplier_total||0).toLocaleString()}</p>
      <p><strong>FrostTech Margin:</strong> ₦${Number(q.frosttech_margin_amount||0).toLocaleString()}</p>
      <p><strong>Customer Total:</strong> ₦${Number(q.customer_total||0).toLocaleString()}</p>
      <p><strong>Status:</strong> ${escapeHtml(q.status||"submitted")}</p>
      <button class="btn-primary" onclick="selectSupplierQuote('${q.id}')">Select Quotation</button>
    </div>
  `).join("");
}

async function selectSupplierQuote(id){
  const {data:quote,error:getError}=await sb
    .from("supplier_quotes")
    .select("id,request_id")
    .eq("id",id)
    .single();

  if(getError){
    message("Unable to find quotation: "+getError.message,"error");
    return;
  }

  const {error:rejectError}=await sb
    .from("supplier_quotes")
    .update({status:"rejected"})
    .eq("request_id",quote.request_id)
    .neq("id",id)
    .eq("status","submitted");

  if(rejectError){
    message("Could not update other quotations: "+rejectError.message,"error");
    return;
  }

  const {error}=await sb
    .from("supplier_quotes")
    .update({
      status:"selected",
      customer_quote_status:"draft"
    })
    .eq("id",id);

  if(error){
    message("Quotation selection failed: "+error.message,"error");
    return;
  }

  message("Supplier quotation selected.","success");
  loadSupplierQuotes();
}

function escapeHtml(value){
  return String(value??"")
    .replace(/&/g,"&amp;")
    .replace(/</g,"&lt;")
    .replace(/>/g,"&gt;")
    .replace(/"/g,"&quot;")
    .replace(/'/g,"&#039;");
}

document.addEventListener("DOMContentLoaded",()=>{
  $("loginForm")?.addEventListener("submit",e=>{
    e.preventDefault();
    loginAdmin();
  });

  $("logoutBtn")?.addEventListener("click",logoutAdmin);

  $("refreshBtn")?.addEventListener("click",()=>{
    loadQuoteRequests();
    loadSupplierQuotes();
  });

  status("Supabase connection initialized successfully.","status-success");
  checkSession();
});
