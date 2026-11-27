# FrostTech Bookkeeping Production Integration Record — 27 November 2026

## Integration checkpoint

The rehearsed bookkeeping schema package has been copied into the production repository on `main` as version-controlled source. This is a repository integration step, **not a database deployment**.

### Production repository files

- `supabase/migrations/20261127190000_create_bookkeeping_core.sql`
- `supabase/rollback/20261127190000_create_bookkeeping_core_rollback.sql`

The migration was copied from the isolated test branch after the no-cost PostgreSQL rehearsal passed. The migration header now records the rehearsal and its additive scope.

## Production database findings

- Production currently has zero `ft_bookkeeping_*` tables.
- The four bookkeeping permissions already exist in `admin_role_permissions` for `finance_admin`: `bookkeeping.read`, `bookkeeping.prepare`, `bookkeeping.reports.read`, and `bookkeeping.documents.manage`.
- Production `admin_accounts` currently contains an active Super Administrator only; no Finance Administrator assignment was found. The production auth user list contains an active profile for `walterunaj@gmail.com` but that user has no admin assignment. The expected Finance Administrator email `onajite1968@gmail.com` was not found as a production auth user in the inspected records. No user ID was guessed and no account was created or appointed.
- The four bookkeeping permissions are correctly stored under `finance_admin`. The role permission table uses the `permission` column (not `permission_key`).
- Existing role constraints and `admin_get_my_role()` still allow six departmental role labels: `operations_admin`, `supplier_admin`, `finance_admin`, `catalogue_admin`, `supplier_catalogue_admin`, and `advertisers_admin`. The intended operating model has four departmental heads, so `supplier_admin` and `catalogue_admin` are a legacy/transition mismatch. Keep them for backward compatibility until every account and dependent policy has been mapped; do not remove or rename them as part of this bookkeeping release.
- The Finance permission set currently contains 20 entries. It includes bookkeeping read/prepare/reports/documents, payment verification and reading, financial reports, tax assessment/remittance and supplier tax-profile work, and supplier-settlement preparation/read/audit. It does not include a supplier-settlement approval permission or tax-rule management permission. Super Admin remains the only final settlement approver and tax-rule authority under the agreed boundary.
- `admin_accounts`, `admin_role_permissions`, and `profiles` have RLS enabled. The inspected permission and admin tables have no direct browser policies; the existing role-check RPCs are the intended access path. Existing helper functions are executable by `authenticated` and `service_role`, not `anon`.
- Existing production role lookup helpers `admin_get_my_role()`, `admin_has_permission(text)`, and `is_super_admin()` are present, SECURITY DEFINER with an empty search_path, and not executable by anon. The bookkeeping migration reuses these helpers and does not replace them.
- Production bookkeeping migration history contains no prior bookkeeping migration.

## Role and permission reconciliation — 27 November 2026

Read-only inspection confirms the bookkeeping permission keys match the production helper contract: `admin_has_permission(required_permission text)`. The production function checks active admin assignment and active profile, and grants the Super Admin bypass. The bookkeeping page calls the correct RPC argument name and gates reports, preparation and document controls separately. The database migration uses the same helpers for RLS and journal-state guards.

**Outstanding account action:** the Finance Administrator must first exist as a production Auth user and then be appointed by the Super Administrator through the approved admin workflow. Do not insert a guessed UUID or grant a role directly as a shortcut. The existing active Super Admin account is confirmed. The known Walter auth profile is not an administrator assignment.

**Outstanding role consolidation:** map the legacy supplier-only and catalogue-only roles to the agreed combined Supplier & Catalogue department through a separately reviewed, dependency-aware migration. Preserve current role values until all dependent policies, RPCs, pages, and assigned accounts are reconciled.

## What was deliberately not changed

- No SQL was applied to the production database.
- No production admin role was appointed or changed.
- No existing tax settings, finance records, tables, functions, policies, or storage buckets were modified.
- A production-compatible `bookkeeping-admin.html` page was added to `main`, and a link was added to `finance-admin.html`. The page uses the production project URL/key, existing role RPCs, and a missing-table guard. It is code-integrated but remains data-inactive until the bookkeeping tables exist. The sign-in UI and reset redirect still require a live browser smoke test before being treated as release-ready.
- No opening balances, journal entries, expenses, shareholder-loan records or bank statement data were imported.

## Rehearsal evidence

The candidate passed the isolated-schema PostgreSQL transaction rehearsal:
- 12 tables, 2 identity sequences, 31 RLS policies and 14 non-internal triggers created.
- Anonymous access restrictions and least-privilege authenticated grants checked.
- Journal audit capture, append-only audit enforcement and private document path redaction checked.
- All temporary schema and test data rolled back.
- A generated reconciliation difference column defect found during the first attempt was corrected and the complete rehearsal passed.

The temporary rehearsal schema was confirmed absent after rollback. The original 12 public test bookkeeping tables remained intact.

## Remaining production release gates

1. Confirm/appoint the production Finance Administrator through the existing Super Admin-controlled admin workflow. Do not directly insert a guessed user ID.
2. Apply the migration to production only after the owner approves the deployment window and a recoverable production backup is confirmed.
3. Run production schema and Supabase security advisors immediately after deployment.
4. Browser-smoke-test the new production bookkeeping page and its Finance entry link; confirm sign-in, sign-out, reset redirect, and role checks. Do not expose any test login or test client.
5. Verify authenticated Finance preparation and Super Admin approval/posting, including rejected and immutable posted journals.
6. Implement and verify the private bookkeeping-document storage bucket and access policies before enabling uploads.
7. Reconcile the opening records from the bank statement: ₦100,000 interest-free shareholder loan liability, ₦10,000 legal-search expense, and ₦90,000 bank ledger balance. Do not import the test rows or post the legal-search expense until source and approval state are reconciled.

## Decision

**Repository integration: completed. Production database deployment: pending explicit deployment approval and backup confirmation.**

This separation preserves the production system while moving the migration source into the production codebase, ready for controlled release.