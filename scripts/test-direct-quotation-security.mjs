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
  has(payment, /tx\.reference!==ref/i);
  has(payment, /String\(tx\.status\)\.toLowerCase\(\)!=="success"/i);
  has(payment, /String\(tx\.currency\)\.toUpperCase\(\)!=="NGN"/i);
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
  has(fee, /quote\.environment!=="development"/i);
  has(fee, /tx\\.reference!==ref/i);
  has(fee, /String\(tx\.status\)\.toLowerCase\(\)!=="success"/i);
  has(fee, /String\(tx\.currency\)\.toUpperCase\(\)!=="NGN"/i);
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
