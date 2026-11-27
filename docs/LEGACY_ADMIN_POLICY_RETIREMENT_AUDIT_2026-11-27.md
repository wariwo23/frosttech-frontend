# Legacy Administrator Authorization Retirement Audit
Date: 27 November 2026
Production project: `nftxptjpgidcsgtaltjn`
Isolated test project: `gqnidjifiobhqhnxjlow`

## Findings
- The legacy `public.is_admin()` function is SECURITY DEFINER, callable by anon and authenticated, and returns true when `profiles.role='admin'` and the profile is active.
- Production currently has one active `profiles.role='admin'` profile linked to one active Super Administrator account. No active departmental administrator accounts exist.
- The isolated test project has an Operations account whose profile role is also `admin`; under the legacy helper this makes the Operations account pass `is_admin()`. This demonstrates why legacy profile-role authorization is unsafe even though production currently has no active departmental accounts.
- No public view definitions reference `is_admin()`. Database function-body audit found no remaining SECURITY DEFINER function callers beyond the helper itself. The remaining dependencies are RLS policies.
- Remaining policies were found on: admin_controls, advertisement_enquiries, advertising_packages, advertising_payments, advertising_terms_acceptance, customer_requests, customers, notifications and order_quotation_snapshots.
- Department permissions already exist: Operations `customer_requests.manage`; Finance `payments.read`; Advertisers & Communications `advertisements.review`, `advertisers.manage`, and `notifications.manage`.

## Prepared policy design
- Global admin controls and advertising package pricing: Super Administrator only.
- Advertisement enquiries: Advertisers & Communications review permission.
- Advertising payment records: Finance read-only; advertiser self-read retained; Super Administrator full control.
- Advertising terms: Advertisers & Communications read; advertiser self-read retained; Super Administrator full control.
- Customer requests: Operations permission plus customer-owned access.
- Customer profiles: customer self-service retained; Operations read-only; Super Administrator full control.
- Notifications: Communications permission plus own-notification read.
- Approved order quotation snapshots: customer order-owner read plus Super Administrator cross-customer read. Department access remains through existing permission-checked RPCs to avoid exposing the full JSON snapshot (which may include supplier-cost/margin fields).
- After replacing every policy reference, revoke anon/authenticated EXECUTE on the legacy `is_admin()` helper.

## Release files
- `supabase/migrations/20261127234500_legacy_admin_policy_retirement.sql`
- `supabase/rollback/20261127234500_legacy_admin_policy_retirement_rollback.sql`
- `supabase/tests/legacy_admin_policy_retirement_regression.sql`
- `supabase/test-fixtures/20261127234500_legacy_admin_policy_test_fixture.sql`

## Boundaries
This audit has not modified production data or policies. The migration must be applied to the isolated project and tested before any production approval. Employment remains paused; no employee or admin accounts are created or invited.

## Isolated validation completed
- Applied the migration to the isolated test project successfully.
- Regression script returned PASS.
- Verified that no RLS policy still references `is_admin()`.
- Verified `anon` and `authenticated` can no longer execute `public.is_admin()`.
- Verified Operations permission boundaries: customer request management works, Super Administrator identity is false, and Finance/Advertiser permissions are denied.
- Verified Super Administrator retains Operations, Finance and Advertiser permissions through `admin_has_permission`.
- Executed the rollback successfully, reapplied the migration, and reran the regression script: PASS.
- Frontend repository code search found no runtime invocation of the legacy `is_admin` RPC; matches were historical migration/rollback/audit documentation.
- Test security advisors still report other SECURITY DEFINER RPC grants and 25 RLS-enabled/no-policy tables in the isolated project. Those are separate findings and are not silently altered by this policy-retirement migration.

## Production release gate
- The production migration has NOT been applied.
- Production audit still shows 10 policies referencing `is_admin()` and the helper remains executable by anon/authenticated until this release is approved.
- No production records, customer requests, payment rows, advertisement packages, notification records, or quotation snapshots were changed during this stage.
- Approval is required before applying `20261127234500_legacy_admin_policy_retirement` to production.
