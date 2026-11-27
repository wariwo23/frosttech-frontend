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
- Production `admin_accounts` currently contains an active Super Administrator only; no Finance Administrator assignment was found.
- Existing production role lookup helpers `admin_get_my_role()`, `admin_has_permission(text)`, and `is_super_admin()` are present, SECURITY DEFINER with an empty search_path, and not executable by anon. The bookkeeping migration reuses these helpers and does not replace them.
- Production bookkeeping migration history contains no prior bookkeeping migration.

## What was deliberately not changed

- No SQL was applied to the production database.
- No production admin role was appointed or changed.
- No existing tax settings, finance records, tables, functions, policies, or storage buckets were modified.
- No bookkeeping page was published to production. The isolated-test UI depends on the test client and test login route; it must be adapted to the production client and role-entry flow after the database foundation is deployed.
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
4. Adapt the bookkeeping page to production Supabase client, production Finance sign-in/entry route, and verified RPC/table grants. Do not publish the isolated-test login link or test client.
5. Verify authenticated Finance preparation and Super Admin approval/posting, including rejected and immutable posted journals.
6. Implement and verify the private bookkeeping-document storage bucket and access policies before enabling uploads.
7. Reconcile the opening records from the bank statement: ₦100,000 interest-free shareholder loan liability, ₦10,000 legal-search expense, and ₦90,000 bank ledger balance. Do not import the test rows or post the legal-search expense until source and approval state are reconciled.

## Decision

**Repository integration: completed. Production database deployment: pending explicit deployment approval and backup confirmation.**

This separation preserves the production system while moving the migration source into the production codebase, ready for controlled release.