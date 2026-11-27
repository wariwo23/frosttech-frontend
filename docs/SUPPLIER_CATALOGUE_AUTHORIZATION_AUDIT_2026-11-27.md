# Supplier & Catalogue Production Authorization Audit
Date: 27 November 2026
Production Supabase project: `nftxptjpgidcsgtaltjn`
Isolated test project: `gqnidjifiobhqhnxjlow`
Repository: `wariwo23/frosttech-frontend`

## Scope inspected
- Supplier application listing and review RPCs
- Supplier quotation listing, rejection and selection RPCs
- Supplier and supplier-quotation RLS policies
- Product catalogue RPCs and product RLS/column grants
- Four-department permission mappings
- Supplier and catalogue frontend compatibility

## Production findings
1. `supplier_admin_list_applications()` requires `supplier_applications.manage`.
2. `admin_review_supplier(uuid,text,text)` requires `supplier_verification.manage`, but its previous implementation did not lock the supplier row and set `is_active=true` for every status except `suspended`. The prepared replacement adds a row lock and activates only `approved`.
3. The production `suppliers` table has broad legacy administrator policies using `is_admin()` for SELECT/INSERT/UPDATE/DELETE. The prepared migration removes those policies and grants table SELECT only to the supplier owner or users with `supplier_applications.read`. Supplier decisions remain RPC-only.
4. Supplier quotations are protected by RLS. Supplier accounts can read and submit their own quotations only while the linked supplier is active and verified. Direct administrator table access remains Super-Admin-only; department access is through permission-checked RPCs requiring `supplier_quotes.manage`.
5. Product catalogue RPCs require `products.manage`, `selling_prices.manage`, and `stock.manage`. `catalogue_list_products()` omits `supplier_cost`.
6. **Production supplier-cost confidentiality is intact at the table-grant layer.** `anon` and `authenticated` have SELECT only on the public catalogue columns; neither has SELECT/INSERT/UPDATE on `supplier_cost`, and neither has direct product-table INSERT/UPDATE/DELETE. Super Admin supplier-cost access is through dedicated RPCs.
7. The consolidated Supplier & Catalogue role has the supplier application, verification, quotation, catalogue, product, selling-price and stock permissions. Finance settlement permissions remain separate.
8. Frontend compatibility issue found: `admin.html` product loader selects `supplier_id` directly from `products`, but production grants do not include SELECT on that column. The field is not used by the loader's rendered product list. A small frontend query correction (remove `supplier_id` from that SELECT list) is recommended. It has NOT been committed or deployed pending approval.

## Isolated test reconciliation and verification
The test database originally differed from production:
- It lacked canonical `supplier_catalogue_admin` in role constraints.
- Its supplier admin list RPC and catalogue RPCs did not match the production frontend contract.
- It granted broad direct table privileges on `products`, including SELECT/INSERT/UPDATE on `supplier_cost`.

The test-only fixture `supabase/test-fixtures/20261127225000_supplier_catalogue_schema_alignment.sql` was updated and applied to the isolated test database. It:
- Adds the canonical combined role while retaining legacy role keys.
- Adds the production-compatible supplier application listing RPC and catalogue RPC set.
- Aligns public product-table grants with production: public catalogue fields are readable; supplier cost and direct product writes are not.
- Does not add staff accounts or send invitations.

The supplier authorization migration `20261127230000_supplier_catalogue_authorization_hardening` was applied to the isolated test database only.

Verified isolated tests:
- Regression assertions: PASS.
- Supplier & Catalogue role can list supplier applications and invoke the review RPC; a non-existent supplier is rejected after authorization.
- A transactional review of an existing approved test supplier back to pending made it inactive/unverified as expected; the supplier row and audit entry were rolled back.
- Supplier quotation list/select/reject RPC authorization checks pass; invalid quotation IDs are rejected without changing quotation records.
- Catalogue list RPC works for Supplier & Catalogue role and does not return `supplier_cost`.
- Finance role is denied supplier application and catalogue-management permissions.
- Super Administrator retains supplier application, quotation and catalogue access.
- Supplier owner can read their own supplier profile; owner-scoped quotation policies remain in place.
- Public catalogue fields remain readable, while `supplier_cost` SELECT/INSERT/UPDATE and direct product-table writes are denied.

Temporary test-role changes were executed inside transactions and rolled back. No supplier, quote, product, price, payment, settlement or customer records were changed.

## Release files
- `supabase/migrations/20261127230000_supplier_catalogue_authorization_hardening.sql`
- `supabase/rollback/20261127230000_supplier_catalogue_authorization_hardening_rollback.sql`
- `supabase/tests/supplier_catalogue_authorization_hardening_regression.sql`
- `supabase/test-fixtures/20261127225000_supplier_catalogue_schema_alignment.sql`

The rollback restores the prior broad `is_admin()` supplier policies and the prior supplier-review function behavior. It should be used only if the new release causes an operational issue because it restores the authorization weakness.

## Not yet done
- The production migration has NOT been applied.
- Production frontend changes have NOT been made or deployed.
- GitHub Pages browser smoke tests have NOT been performed.
- No employee account or invitation was created; employment remains paused.

## Next release gate
1. Approve the one-line `admin.html` product query compatibility correction.
2. Review the prepared production migration and rollback.
3. Obtain explicit approval to apply the supplier authorization migration to production.
4. After production application, verify the Super Admin and public catalogue paths and recheck supplier-cost grants.
