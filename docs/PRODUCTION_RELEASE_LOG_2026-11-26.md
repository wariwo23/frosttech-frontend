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


## Consolidated four-department role foundation applied

### Database migration 20261126211500

Applied successfully to production Supabase.

- Expanded administrator role constraints to support `supplier_catalogue_admin` and `advertisers_admin`, retaining the existing legacy role values for compatibility.
- Expanded employee department constraints to support `supplier_catalogue` and `advertisers_communications`, retaining legacy department values.
- Added consolidated Supplier & Catalogue permissions for supplier application review/verification and catalogue/product/selling-price/stock management.
- Added Advertisers & Communications permissions for advertiser/document review, communications and notifications.
- Updated `admin_get_my_role()` to recognize the two new roles while retaining Super Admin checks.
- Updated `admin_appoint_departmental_admin(uuid,text)` so only Super Admin can appoint eligible active employee accounts to the role matching their department. Super Admin protection, email confirmation and completed employee-account setup checks remain.

Post-migration inspection confirmed the three constraints contain the new role/department values and both permission groups contain the intended mappings. The production admin account inventory still contains only the existing active Super Admin; no departmental accounts or employees were created or changed.

### Frontend role compatibility commits

- `5a0c7178abdc359499ff4e67b8d40fcfafc01c1b`: departmental sign-in routes the two new roles to their respective workspaces.
- `71271cdcd5e28086dbfbc33cd1b1a00418a76de8`: Super Admin operator-management department and role maps updated.
- `37ec28e8049f893614ccb95612c562848d29613f`: catalogue workspace accepts the consolidated Supplier & Catalogue role.
- `8e1d71df054efad1305a81e44d1fca8930d1930b` and `fad115a211b02803abc3c24cf0fc062738e67797`: supplier workspace accepts consolidated role but hides the financial supplier-quotation panel; supplier application review remains available through its permission-checked RPC.
- `ebf7e78d87690b0f17c8dd7daa4082c943dd529d`: employee creation form includes the consolidated departments.
- `63c3c10789a4cb7b6353f0a47986cf207422842a`: added a read-only Advertisers & Communications landing page pending secure review/notification UI compatibility.
- `80739b43a68bed2691f0f8748923d39af2db4063`: added a catalogue-workspace link for consolidated Supplier & Catalogue administrators.

### Remaining gates — do not treat as full production launch

- The Advertisers & Communications landing page is deliberately read-only. Existing advertising review uses legacy `is_admin()` and a broad direct-table workflow; it must be migrated to permission-specific RPC/Edge Function authorization before operational access is enabled.
- Supplier quote financial listing/selection APIs still need the separately prepared security migration and UI compatibility work. The consolidated role has not been granted `supplier_quotes.manage`.
- Legacy supplier and catalogue roles remain accepted for existing account compatibility. A later controlled migration may retire them only after all account and frontend dependencies are reconciled.
- Operations standard quotation revision dependencies remain outstanding.
- Finance permission and bookkeeping/tax/settlement compatibility remains outstanding.
- GitHub Pages deployment and browser regression for the commits above remain unverified in this pass.
