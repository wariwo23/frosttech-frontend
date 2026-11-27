# Supplier & Catalogue Production Authorization Audit
Date: 27 November 2026
Production Supabase project: `nftxptjpgidcsgtaltjn`
Repository: `wariwo23/frosttech-frontend`

## Scope inspected
- Supplier application listing and review RPCs
- Supplier quotation listing, rejection and selection RPCs
- Supplier and supplier-quotation RLS policies
- Product catalogue RPCs and product RLS
- Four-department permission mappings
- Supplier and catalogue frontend compatibility

## Findings
1. `supplier_admin_list_applications()` requires `supplier_applications.manage`.
2. `admin_review_supplier(uuid,text,text)` requires `supplier_verification.manage`, but the prior implementation did not lock the supplier row and set `is_active=true` for every status except `suspended`. The proposed replacement adds a row lock and activates only `approved`.
3. The suppliers table had broad legacy administrator policies using `is_admin()` for SELECT/INSERT/UPDATE/DELETE. The replacement migration removes those policies and grants table SELECT only to the supplier owner or users with `supplier_applications.read`. Supplier decisions remain RPC-only.
4. Supplier quotations are protected by RLS. Supplier accounts can read and submit their own quotations only while the linked supplier is active and verified. The direct administrator table policy is Super-Admin-only; department access is through permission-checked RPCs requiring `supplier_quotes.manage`.
5. Product catalogue RPCs require the corresponding permissions: `products.manage`, `selling_prices.manage`, and `stock.manage`. The catalogue list projection does not return `supplier_cost`.
6. Product table RLS and column grants prevent client roles from directly reading supplier_cost or directly inserting/updating/deleting products. Public and authenticated product read policies remain separate.
7. The consolidated Supplier & Catalogue role already has application read/manage/review, supplier verification, supplier quote management, product, catalogue, selling-price and stock permissions. Finance settlement permissions remain separate.

## Prepared release files
- `supabase/migrations/20261127230000_supplier_catalogue_authorization_hardening.sql`
- `supabase/rollback/20261127230000_supplier_catalogue_authorization_hardening_rollback.sql`
- `supabase/tests/supplier_catalogue_authorization_hardening_regression.sql`

The migration is deliberately narrow. It does not modify supplier quotations, supplier costs, products, customers, payments, settlements, or existing supplier records. The rollback restores the prior broad `is_admin()` supplier policies and the prior review function; it should be used only if the new release causes an operational issue because it restores the authorization weakness.

## Frontend compatibility
- `supplier-admin.html` reads applications through `supplier_admin_list_applications()` and submits decisions through `admin_review_supplier()`.
- Supplier quotation listing and decisions use `admin_list_supplier_quotes()`, `admin_select_supplier_quote()`, and `admin_reject_supplier_quote()`.
- `supplier.html` reads only the signed-in supplier's own supplier profile.
- No direct supplier-table INSERT/UPDATE/DELETE was found in the inspected active supplier/admin frontends.
- Existing supplier self-service quotation policies are retained.

## Not yet applied or verified
- The migration has been committed to GitHub but has NOT been applied to production or test Supabase.
- Regression SQL has been prepared but has NOT been executed.
- GitHub Pages browser smoke tests have NOT been performed.
- No supplier status, supplier quotation, product, price, payment or customer data was changed.
- No employee account or invitation was created; employment remains paused.

## Release gate
Before applying, confirm the migration and rollback contents, run the regression suite in the isolated test project, and verify supplier owner read, supplier quote submission, department application read/review, quotation selection, catalogue CRUD via RPC, and supplier-cost confidentiality. Production application requires explicit approval.
