# FrostTech production release log — 26 November 2026

## Production changes applied

Production Supabase project: `nftxptjpgidcsgtaltjn`

### Migration 20261126204404 — product supplier-cost read protection

Applied successfully.

- Revoked table-level SELECT on `public.products` from `anon` and `authenticated`.
- Re-granted SELECT only on the public/operational product columns, explicitly excluding `supplier_cost`.
- Revoked TRUNCATE from both client roles.

### Migration 20261126204529 — restrict direct client product writes

Applied successfully.

- Revoked INSERT, UPDATE and DELETE on `public.products` from `anon` and `authenticated`.
- Existing product operations are now expected to use permission-checked catalogue RPCs.

### Production frontend compatibility commit

Commit: `cd76afcd7a1305fc08c4cccc696f240431ef7434`

Updated `admin.html` on production repository `main`:
- Existing product edits call `catalogue_update_product_details` and `catalogue_update_stock`.
- Activation/deactivation calls `catalogue_set_product_active`.
- New product creation calls `catalogue_create_product`.
- Removed direct client-side INSERT/UPDATE calls to `public.products` from this page.
- Existing image upload, supplier pricing workflow, and selected-supplier validation remain in place.

## Post-migration database verification

Confirmed after both migrations:
- anon SELECT on `products.supplier_cost`: false.
- authenticated SELECT on `products.supplier_cost`: false.
- anon/authenticated SELECT on ordinary product `name`: true.
- anon/authenticated TRUNCATE: false.
- anon/authenticated INSERT, UPDATE and DELETE: false.

Health advisor returned no health lints. Security advisor still reports 21 RLS-enabled tables without policies (INFO), 3 publicly executable SECURITY DEFINER functions, 78 authenticated-executable SECURITY DEFINER functions, and leaked-password protection disabled. These findings require function-by-function review; they were not mass-revoked because some are intentional public workflows and protected RPC entry points.

## Important deployment caveat

The production frontend source is committed to GitHub `main`, but GitHub Pages deployment and browser-level product create/edit/activation smoke tests were not verified in this pass. The source commit's combined GitHub status returned no status checks. Do not report the live site as fully verified until the Pages deployment and browser workflow are confirmed.

## Remaining production integration

These two product-security migrations do not complete the overall four-department production integration. Outstanding work includes:
- reconcile migration history/source files (production has migration entries not yet mirrored in the repository);
- four-department role constraints and permission mappings;
- Operations quotation revision RPC and frontend compatibility;
- Supplier operational quote projection and final-selection authority;
- Finance bookkeeping/tax/settlement permissions and records;
- Advertisers & Communications role and payment/notification authorization;
- Edge Function compatibility and security review;
- storage policy review and full regression.

No customer, supplier, payment or financial records were deleted or overwritten by these migrations.
