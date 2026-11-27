# Quotation & Direct-Quotation Authorization Audit
Date: 27 November 2026
Production project: `nftxptjpgidcsgtaltjn`
Isolated test project: `gqnidjifiobhqhnxjlow`

## Scope
- Direct quotation draft create/read/update.
- Quotation item access and finance visibility.
- Private quotation pricing snapshots.
- Direct quotation revision, item replacement and submission RPCs.
- Alternative proposal review financial visibility.
- Guest quote-request INSERT-only access.
- Legacy `is_admin()` policies.

## Findings
1. Direct quotation revision, item replacement and submission RPCs already require `quotations.manage`. They use SECURITY DEFINER and enforce draft/status/ownership/line-total/accepted-alternative/payment-fee invariants.
2. `frosttech_get_request_alternative_review_v1` already checks customer-request management and reveals commercial terms only when `quotations.read_financial` is granted.
3. Production role mapping already gives `operations_admin` `quotations.manage` and `finance_admin` `quotations.read_financial`.
4. The production `admin_quotations` table had a Super-Admin ALL policy and Finance SELECT policy, but no Operations policy. The frontend in `admin.html` directly reads quotations, inserts/updates drafts, and reads request contact details. Thus the current four-department policy does not yet support Operations direct-quotation workflow.
5. `admin_quotation_items_admin_manage` still used legacy `is_admin()` for ALL actions. The UI reads items directly but saves them through the permission-checked RPC. The prepared correction removes direct table writes and adds Operations and Finance SELECT policies.
6. `admin_quotation_pricing_snapshots` still used legacy `is_admin()`. The Operations quotation UI directly upserts and reads this private draft pricing snapshot. The prepared correction grants table access only to `quotations.manage` (Operations and Super Admin); Finance does not receive this private input table.
7. Anonymous roles had broad table grants on `admin_quotations` and `admin_quotation_items`, and SELECT/UPDATE/DELETE grants on `quote_requests`. RLS currently blocks anonymous reads of protected rows, but those unnecessary grants are removed. Guest quote submission remains INSERT-only.
8. Existing Super Admin quotation access and Finance read-only financial visibility are retained. Customer-owned item reads and guest quote-request INSERT policy remain unchanged.

## Data inspected
Production counts at audit time: 10 quotations, 12 quotation items, 1 private pricing snapshot, 11 quote requests. No rows were changed during this inspection.

## Prepared release files
- `supabase/migrations/20261127233000_quotation_authorization_hardening.sql`
- `supabase/rollback/20261127233000_quotation_authorization_hardening_rollback.sql`
- `supabase/tests/quotation_authorization_hardening_regression.sql`
- `supabase/test-fixtures/20261127233000_quotation_authorization_test_alignment.sql`

## Release boundary
The migration has NOT been applied to production. The isolated test database must be aligned and tested first. The rollback restores the old broad `is_admin()` policies and anonymous grants; use only for emergency recovery. No quotation, payment, customer, supplier, or employee data has been changed by this audit.

## Isolated regression results
- The test-only pricing snapshot table and permission rows were aligned.
- The isolated environment was missing the four production quotation RPC definitions. The fixture was therefore extended with the exact current production definitions for revision, item replacement, submission and alternative review, so the authorization regression validates the real function bodies rather than placeholders.
- Applied the prepared migration to the isolated test project only.
- Regression script result: PASS.
- Operations quotation management and private pricing snapshot access passed.
- Finance read-only quotation and line-item access passed; Finance has no `quotations.manage` permission and no pricing-snapshot policy.
- Super Administrator retains full quotation and direct quotation-item authority.
- Existing RPCs retain their `quotations.manage` checks; alternative review retains its `quotations.read_financial` visibility gate.
- Anonymous direct access to quotations/items is revoked; guest `quote_requests` remains INSERT-only.
- Test fixture/function synchronization and migration were confined to the isolated test project. No production quotation, request, item, pricing snapshot, fee, customer or payment records were changed.

## Additional implementation safeguard
The migration includes a separate `super_admin_quotation_items_manage` policy using `is_super_admin()`. This explicitly preserves Super Administrator direct item authority while department admins use the narrower read policy and permission-checked item RPC.

## Production release status
The production migration remains unapplied pending explicit approval. The production data inventory at audit time remains 10 quotations, 12 quotation items, 1 private pricing snapshot and 11 quote requests.

- Rollback validation: PASS. The isolated migration was rolled back, reapplied, and the full regression script passed again after reapplication.
