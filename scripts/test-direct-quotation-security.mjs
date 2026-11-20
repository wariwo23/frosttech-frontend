
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/20261119120000_frosttech_independent_quotations_foundation.sql", "utf8");
const payment = readFileSync("supabase/functions/direct-order-payment/index.ts", "utf8");
const fee = readFileSync("supabase/functions/direct-quotation-fee/index.ts", "utf8");
const decision = migration.slice(migration.indexOf("create or replace function public.frosttech_decide_direct_quotation("), migration.indexOf("$decision$;") + 11);
const reserve = migration.slice(migration.indexOf("create or replace function public.frosttech_reserve_direct_order_payment("), migration.indexOf("$reserve$;") + 10);
const record = migration.slice(migration.indexOf("create or replace function public.frosttech_record_direct_order_payment_success("), migration.indexOf("$orderpay$;") + 12);
const has = (source, pattern) => assert.match(source, pattern);

test("one direct quotation can create at most one order", () => {
  has(migration, /create unique index if not exists orders_one_per_direct_quotation_idx[\s\S]*?on public\.orders\(direct_quotation_id\) where direct_quotation_id is not null/i);
});

test("acceptance requires claimed invitation, confirmed matching customer and explicit terms", () => {
  has(decision, /claimed_by=p_actor and i\.revoked_at is null/i);
  has(decision, /email_confirmed_at is not null/i);
  has(decision, /p_terms_accepted is not true/i);
  has(decision, /for update/i);
});

test("acceptance writes order, accepted status and immutable snapshot in one database function", () => {
  has(decision, /insert into public\.orders[\s\S]*?direct_quotation_id/i);
  has(decision, /update public\.frosttech_direct_quotations[\s\S]*?set status='accepted'/i);
  has(decision, /insert into public\.frosttech_direct_order_snapshots/i);
});

test("decline requires a reason and repeated decisions are idempotent", () => {
  has(decision, /Please provide a valid reason for declining this offer/i);
  has(decision, /already_recorded',true/i);
});

test("payment reservation locks the order and reuses an existing pending attempt", () => {
  has(reserve, /where o\.id=p_order_id and o\.direct_quotation_id is not null\s+for update/i);
  has(reserve, /status='successful'/i);
  has(reserve, /status='pending'[\s\S]*?for update/i);
  has(reserve, /v_customer_user is distinct from p_actor/i);
  has(reserve, /v_order\.status<>'awaiting_payment'/i);
  has(reserve, /v_order\.environment<>'development'/i);
  has(reserve, /insert into public\.payments/i);
  has(migration, /revoke all on function public\.frosttech_reserve_direct_order_payment\(uuid,uuid,text\)[\s\S]*?from public,anon,authenticated/i);
  has(migration, /grant execute on function public\.frosttech_reserve_direct_order_payment\(uuid,uuid,text\)[\s\S]*?to service_role/i);
});

test("checkout calls the reservation RPC and refuses uncertain duplicate initialization", () => {
  has(payment, /rpc\("frosttech_reserve_direct_order_payment"/i);
  has(payment, /reservation\.reused===true/i);
  has(payment, /A payment initialization is already in progress or requires reconciliation/i);
  has(payment, /PAYSTACK_TEST_SECRET_KEY/i);
  has(payment, /order\.environment!=="development"/i);
});

test("Paystack order verification checks reference, success, NGN and exact amount", () => {
  has(payment, /tx\.reference\s*!==\s*ref/i);
  has(payment, /String\(tx\.status\)\.toLowerCase\(\)\s*!==\s*"success"/i);
  has(payment, /String\(tx\.currency\)\.toUpperCase\(\)\s*!==\s*"NGN"/i);
  has(payment, /Number\(tx\.amount\)!==Math\.round\(Number\(payment\.amount\)\*100\)/i);
  has(payment, /rpc\("frosttech_record_direct_order_payment_success"/i);
});

test("payment recording checks customer ownership and updates payment plus order atomically", () => {
  has(record, /where o\.id=p_order_id and o\.direct_quotation_id is not null\s+for update/i);
  has(record, /v_customer_user is distinct from p_actor/i);
  has(record, /v_payment\.currency<>'NGN'/i);
  has(record, /v_payment\.payment_method<>'paystack'/i);
  has(record, /round\(v_payment\.amount\*100\)<>round\(v_order\.customer_total\*100\)/i);
  has(record, /update public\.payments set status='successful'/i);
  has(record, /update public\.orders set status='paid'/i);
});

test("processing-fee checkout remains Test Mode only and validates Paystack response", () => {
  has(fee, /PAYSTACK_TEST_SECRET_KEY/i);
  has(fee, /quote\.environment\s*!==\s*"development"/i);
  has(fee, /tx\.reference\s*!==\s*ref/i);
  has(fee, /String\(tx\.status\)\.toLowerCase\(\)\s*!==\s*"success"/i);
  has(fee, /String\(tx\.currency\)\.toUpperCase\(\)\s*!==\s*"NGN"/i);
});

test("receipt constraint keeps request-based fees and adds a separate direct-quotation fee path", () => {
  const receipt = migration.slice(migration.indexOf("add constraint payment_receipts_source_integrity_check"), migration.indexOf("create index if not exists payment_receipts_direct_quotation_idx"));
  has(receipt, /receipt_type='quotation_admin_fee'[\s\S]*?quote_request_id is not null[\s\S]*?order_id is null/i);
  has(receipt, /receipt_type='quotation_admin_fee'[\s\S]*?quote_request_id is null[\s\S]*?direct_quotation_id is not null/i);
  has(receipt, /receipt_type='final_order_payment'/i);
});

test("critical customer decision and payment RPCs are service-role only", () => {
  for (const fn of ["frosttech_decide_direct_quotation", "frosttech_record_direct_order_payment_success", "frosttech_record_direct_quote_fee_success"]) {
    const escaped = fn.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    has(migration, new RegExp("revoke all on function public\\." + escaped + "[\\s\\S]*?from public,anon,authenticated", "i"));
    has(migration, new RegExp("grant execute on function public\\." + escaped + "[\\s\\S]*?to service_role", "i"));
  }
});


const sourcing = readFileSync("supabase/migrations/20261119170000_frosttech_direct_order_sourcing_finance.sql", "utf8");
const sourcingPage = readFileSync("direct-order-sourcing.html", "utf8");
const financePage = readFileSync("finance-admin.html", "utf8");

test("direct-order sourcing tables are private, RLS protected and audit history is immutable", () => {
  has(sourcing, /create table if not exists public\.frosttech_direct_order_item_sourcing/i);
  has(sourcing, /create table if not exists public\.frosttech_direct_order_sourcing_audit/i);
  has(sourcing, /enable row level security/i);
  has(sourcing, /revoke all on public\.frosttech_direct_order_item_sourcing from anon,authenticated/i);
  has(sourcing, /revoke all on public\.frosttech_direct_order_sourcing_audit from anon,authenticated/i);
  has(sourcing, /before update or delete on public\.frosttech_direct_order_sourcing_audit/i);
});

test("all direct-order supplier cost reads and writes require Super Administrator", () => {
  for (const fn of ["frosttech_super_admin_list_direct_order_sourcing","frosttech_super_admin_assign_direct_order_item_supplier","frosttech_super_admin_record_direct_order_item_cost"]) {
    const start = sourcing.indexOf("create or replace function public." + fn);
    assert.notEqual(start, -1, fn + " exists");
    const tag = fn === "frosttech_super_admin_list_direct_order_sourcing" ? "$list_sourcing$;" :
      fn === "frosttech_super_admin_assign_direct_order_item_supplier" ? "$assign_sourcing$;" : "$record_sourcing_cost$;";
    const end = sourcing.indexOf(tag, start);
    assert.ok(end > start, fn + " body closes");
    const section = sourcing.slice(start, end);
    has(section, /public\.is_super_admin\(\)/i);
  }
  has(sourcing, /revoke all on function public\.frosttech_super_admin_record_direct_order_item_cost/i);
});

test("supplier reassignment clears stale cost and records audit events", () => {
  has(sourcing, /supplier_id=p_supplier_id,[\s\S]*?supplier_unit_cost=null,[\s\S]*?costed_by=null,[\s\S]*?costed_at=null/i);
  has(sourcing, /'assigned','reassigned','cost_recorded','cost_updated'/i);
  has(sourcing, /insert into public\.frosttech_direct_order_sourcing_audit/i);
});

test("cost entry requires paid order, an assigned supplier and positive cost", () => {
  has(sourcing, /v_order\.status not in \('paid','processing','ready_for_delivery','out_for_delivery','delivered','completed'\)/i);
  has(sourcing, /Assign an approved supplier before recording its cost/i);
  has(sourcing, /round\(p_supplier_unit_cost,2\)<=0/i);
  has(sourcing, /Only active, verified and approved suppliers may be assigned/i);
});

test("Finance direct quotation ledger is separate and excludes supplier costs", () => {
  const start = sourcing.indexOf("create or replace function public.finance_list_direct_quotation_activity");
  const end = sourcing.indexOf("$direct_finance$;", start);
  const financeFn = sourcing.slice(start, end);
  has(financeFn, /admin_has_permission\('quotations.read_financial'\)/i);
  has(financeFn, /'environment',q.environment/i);
  has(financeFn, /'environment',p.environment/i);
  has(financeFn, /from public\.payment_receipts r/i);
  assert.doesNotMatch(financeFn, /supplier_cost|supplier_unit_cost|frosttech_margin/i);
  has(financePage, /finance_list_direct_quotation_activity/i);
  has(financePage, /directDevelopmentRows/i);
  has(financePage, /directProductionRows/i);
});

test("Super Admin sourcing page uses protected RPCs and branded confirmation", () => {
  has(sourcingPage, /admin_get_my_role/i);
  has(sourcingPage, /role!=="super_admin"/i);
  has(sourcingPage, /frosttech_super_admin_list_direct_order_sourcing/i);
  has(sourcingPage, /frosttech_super_admin_assign_direct_order_item_supplier/i);
  has(sourcingPage, /frosttech_super_admin_record_direct_order_item_cost/i);
  has(sourcingPage, /ftConfirmBackdrop/i);
  has(sourcingPage, /sourcing_audit/i);
  assert.doesNotMatch(sourcingPage, /window\.confirm\(/i);
});


test("customer can reconcile the latest recorded order payment without exposing a payment reference", () => {
  has(payment, /if\s*\(!ref\)\s*\{[\s\S]*?\.eq\("status","successful"\)[\s\S]*?\.order\("created_at",\{ascending:false\}\)[\s\S]*?if\(successful\?\.transaction_reference\)[\s\S]*?\.eq\("status","pending"\)[\s\S]*?\.order\("created_at",\{ascending:false\}\)/i);
  has(payment, /No pending or successful payment attempt was found for this order/i);
  has(payment, /order\.customer_id[\s\S]*?customer\.user_id!==user\.id/i);
});

test("customer quotation page exposes an explicit existing-payment reconciliation action", () => {
  const customerPage = readFileSync("direct-quotation.html", "utf8");
  has(customerPage, /id="reconcileOrderPayment"/i);
  has(customerPage, /action:"verify_order",order_id:currentOrderId,token:invite/i);
  has(customerPage, /Check Existing Payment/i);
});

test("recovered payment lookup filters and validates Paystack method, NGN amount and environment", () => {
  has(payment, /\.eq\("payment_method","paystack"\)[\s\S]*?\.eq\("environment",order\.environment\)[\s\S]*?\.eq\("status","successful"\)[\s\S]*?\.eq\("status","pending"\)/i);
  has(payment, /payment\.payment_method!=="paystack"\|\|payment\.currency!=="NGN"\|\|payment\.environment!==order\.environment/i);
  has(payment, /Number\(payment\.amount\)!==Number\(order\.customer_total\)/i);
});


const receiptTriggerMigration = readFileSync("supabase/migrations/20261120102000_harden_receipt_delivery_trigger_function.sql", "utf8");
test("receipt delivery trigger cannot be invoked directly by API roles", () => {
  has(receiptTriggerMigration, /revoke all on function public\.frosttech_create_receipt_delivery_record\(\)[\s\S]*?from public,anon,authenticated/i);
});


const financeActivityFix = readFileSync("supabase/migrations/20261120113000_fix_direct_finance_activity_period.sql", "utf8");
test("Finance reporting includes quote, order, fee, payment and receipt activity within Lagos date boundaries", () => {
  has(financeActivityFix, /q\.created_at >= v_period_start[\s\S]*?q\.submitted_at >= v_period_start[\s\S]*?q\.decision_at >= v_period_start/i);
  has(financeActivityFix, /o\.created_at >= v_period_start/i);
  has(financeActivityFix, /fp\.created_at >= v_period_start[\s\S]*?fp\.verified_at >= v_period_start/i);
  has(financeActivityFix, /p\.created_at >= v_period_start[\s\S]*?p\.paid_at >= v_period_start/i);
  has(financeActivityFix, /r\.paid_at >= v_period_start/i);
  has(financeActivityFix, /at time zone 'Africa\/Lagos'/i);
});


test("reconciling an already-successful payment repairs only an unpaid order idempotently", () => {
  has(payment, /if\(payment\.status!=="successful"\)/i);
  has(payment, /reconciled_existing_success:true/i);
  has(payment, /frosttech_record_direct_order_payment_success/i);
  has(record, /if v_payment\.status='successful' then[\s\S]*?if v_order\.status in \('awaiting_payment','pending'\)[\s\S]*?set status='paid'[\s\S]*?already_recorded',true/i);
});

test("direct order receipt is issued only after the order is confirmed paid", () => {
  has(payment, /if\s*\(paidOrderError\|\|!paidOrder\|\|paidOrder\.status!=="paid"\)[\s\S]*?createReceipt\(db,SERVICE,paidOrder,payment/i);
});

test("automatic delivery remains limited to eligible physical product categories and does not duplicate", () => {
  const delivery = readFileSync("supabase/functions/direct-order-payment/delivery.ts", "utf8");
  has(delivery, /"Air Conditioners"[\s\S]*?"Refrigeration Parts"[\s\S]*?"HVAC Accessories"/);
  has(delivery, /\.eq\("order_id",\s*order\.id\)[\s\S]*?if\s*\(existing\)[\s\S]*?return result/i);
  has(delivery, /if \(insertError\.code === "23505"\)[\s\S]*?concurrentDelivery/i);
});


test("payment recovery prefers a confirmed payment before a newer pending attempt", () => {
  has(payment, /\.eq\("status","successful"\)[\s\S]*?if\(successful\?\.transaction_reference\)[\s\S]*?\.eq\("status","pending"\)/i);
});
