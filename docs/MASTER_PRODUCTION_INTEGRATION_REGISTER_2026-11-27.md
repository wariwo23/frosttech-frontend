# FrostTech Master Production Integration Register
**Checkpoint:** 27 November 2026  
**Purpose:** Move completed, approved work from the isolated test programme into the production system without repeating completed tests, overwriting existing work, duplicating financial records, or weakening security.

## Operating rule

This register is the single integration control record. Each workstream is classified as:
- **IN PRODUCTION** — verified in the production database or production repository.
- **RELEASE CANDIDATE** — implementation exists and is suitable for controlled integration after source reconciliation.
- **RECONCILIATION REQUIRED** — production and test/source differ; do not blindly copy or rerun.
- **HELD** — intentionally deferred by the owner.
- **NOT VERIFIED** — evidence is insufficient; do not claim completion.

No production database migration, code deployment, payment initiation, role appointment, or customer/supplier transaction is authorized merely by this register.

## 1. Production integration baseline

### Verified production database state
Read-only production inspection on 27 November 2026 found:
- Four-department role/permission foundations and the later authorization hardening migrations are present in production migration history.
- Advertising authorization hardening is recorded.
- Supplier/catalogue authorization hardening is recorded.
- Quotation authorization hardening is recorded.
- Legacy admin-policy retirement is recorded; no remaining public policies referencing the legacy `is_admin()` helper were found in the inspected policy set.
- The bookkeeping schema is already present: 12 `ft_bookkeeping_*` tables, 31 policies, 4 bookkeeping functions and 14 non-internal bookkeeping triggers.
- The active administrator assignment returned by the current read-only query is Super Admin only. No departmental appointments are to be created while employment/appointments remain on hold.

### Critical migration-history reconciliation
The live migration history records bookkeeping as version `20261127095530`, name `create_bookkeeping_core`. The production repository contains `supabase/migrations/20261127190000_create_bookkeeping_core.sql`. These identifiers do not match. The live schema is already present, so **do not rerun either bookkeeping migration**. Reconcile the migration source and history identifier in a separate, non-destructive release-record update. Never insert a fabricated migration-history row merely to make the list look aligned.

### Verified production financial baseline
The two opening journal entries are already posted:
1. 20 November 2026: Dr Bank ₦100,000 / Cr Shareholder Loan Payable ₦100,000.
2. 24 November 2026: Dr Legal and Professional Fees ₦10,000 / Cr Bank ₦10,000.

The posted ledger totals ₦110,000 debit and ₦110,000 credit; difference ₦0. These records must not be imported again, duplicated, or reposted. The shareholder financing remains an interest-free liability, not share capital.

## 2. Workstream register

| Workstream | Current classification | Production integration disposition |
|---|---|---|
| Four-department roles and permission model | IN PRODUCTION, with legacy-role compatibility | Preserve canonical four departments and existing legacy role values until dependent accounts, RPCs, policies and pages are mapped. |
| Super Admin authority and department access | IN PRODUCTION foundation; frontend routing needs source reconciliation | Preserve Super Admin as highest authority with cross-department access without re-sign-in. Department heads use separate departmental entry points and do not enter the Super Admin Command Center. |
| Supplier and catalogue authorization | IN PRODUCTION | Preserve protected supplier-cost data, supplier review boundaries and catalogue write restrictions. Do not reapply hardening migrations. |
| Standard and direct quotations | IN PRODUCTION authorization foundation | Preserve Operations management, Finance read-only financial access, Super Admin authority, guest submission and consultation-fee basis. Do not change the approved 2% fee calculation or delivery exclusion. |
| Advertising review and authorization | IN PRODUCTION database/Edge Function authorization foundation | Payment and notification readiness only; no live payment, campaign activation or advertiser approval without the established review process. |
| Advertiser registration V2 | RELEASE CANDIDATE in isolated preview | The test page and login link were deployed to the test Pages branch; user confirmed all password-validation messages respond correctly. Compare its source with production advertiser registration before integrating. No advertiser account was created. |
| Password-policy hardening | RELEASE CANDIDATE | PR #17 remains open/draft. Its 37-test CI result is recorded in the project checkpoint. Review the exact diff and integrate through a production PR; do not change Supabase Auth configuration or employee onboarding. |
| Bookkeeping schema | IN PRODUCTION, source/history reconciliation required | Production schema is ahead of the isolated test database in audit functions/triggers. Do not copy the smaller test schema over production. Reconcile the migration source and record identifiers without reapplying schema. |
| Bookkeeping page and registers | RECONCILIATION REQUIRED | Correct stale “opening entries remain drafts” wording. Expense and Shareholder Loan registers are empty although the corresponding journal entries are posted. Build linked register capture/reconciliation without duplicate postings. |
| Bookkeeping document storage | RECONCILIATION REQUIRED | The private `ft-bookkeeping-documents` bucket is absent. Prepare a private bucket and path-scoped policies as a separate release package before enabling uploads. |
| Tax administration | RELEASE CANDIDATE / NOT YET PRODUCTION-VERIFIED | Test repository contains tax integrity, deduplication, concurrency, settlement-basis and source-normalization migrations. Production migration history does not show these named tax migrations. Reconcile dependencies and tax rules/effective dates before preparing a production release. |
| Supplier settlements and withholding tax | HELD FOR DEPENDENCY REVIEW | Test repository contains a draft supplier-disbursement evidence migration. Do not deploy a draft or initiate settlement. Preserve the approved mixed-payment design and Super Admin final authorization boundary; validate Nigerian withholding-tax treatment with the agreed accounting basis before production settlement requests. |
| Employee onboarding and departmental appointments | HELD | No employee invitations, appointments, activations or role creation. Preserve current records and setup. |
| Notification recovery / SMTP | IN PRODUCTION foundation; live operational readiness not fully verified | Preserve existing notification configuration. Domain/Resend work remains on hold. Do not send test or production notices without an explicit task. |
| Customer/supplier/guest account journeys | RECONCILIATION REQUIRED | Preserve existing accounts and workflows. Integrate only the approved, source-reconciled frontend changes; do not reset or recreate accounts. |
| Main Command Center / departmental mini-centres | RECONCILIATION REQUIRED | The test preview contains separate command-centre pages and department workspaces. Reconcile current production routing and responsibility tiles against the approved four-department architecture before copying pages. |
| Domain, Resend and public launch | HELD | Do not reopen this workstream unless the owner explicitly resumes it. Marketplace remains non-trading. |

## 3. Repository and release-control findings

- Production frontend repository: `wariwo23/frosttech-frontend`, branch `main`.
- Isolated preview repository: `wariwo23/frosttech-test-preview`, branch `command-center-shell-stage1`.
- The repositories are separate; test-preview files are not automatically part of production.
- Open PR #17 is password-policy hardening and remains a draft. It must be reviewed before merge.
- Open PR #10 proposes requiring separate Super Admin sign-in for each department. That conflicts with the approved architecture (Super Admin can enter departments without signing in again). Do not merge it as written; treat it as superseded pending source review.
- Test-only pages, draft migrations and test-specific Supabase URLs/keys must never be copied into production configuration.

## 4. Ordered production integration sequence

### Package 00 — Freeze and reconcile source inventory
- Freeze the current production main SHA and test-preview branch SHA in the release record.
- Record each migration's repository filename, live migration-history version/name, and actual schema effect.
- Mark already-applied migrations so they cannot be replayed.
- Reconcile stale documentation that says production bookkeeping tables are absent or opening entries are drafts.

### Package 01 — Security and four-department compatibility
- Keep existing production authorization hardening in place.
- Review the remaining SECURITY DEFINER functions individually by purpose, caller, grants and permission guard. Do not blanket-revoke authenticated execution.
- Reconcile canonical four-department roles with retained legacy supplier/catalogue role labels and dependent frontend routing.
- Do not create or appoint departmental users while appointments are held.

### Package 02 — Bookkeeping operational completion
- Update the bookkeeping page's posted/draft status text.
- Link the posted legal-search expense and shareholder-loan liability to their respective registers without creating duplicate journal postings.
- Confirm the ₦90,000 closing bank balance and source-document references.
- Prepare private document storage and its access policies before enabling uploads.
- Keep posted journals immutable; corrections must use the approved adjustment workflow.

### Package 03 — Advertiser and account-flow release
- Reconcile advertiser registration V2 with the production advertiser sign-up/login/reset pages.
- Review PR #17 and integrate password validation only after exact-source review.
- Keep company/CAC review separate from account registration.
- Keep payment and notification workflows ready but do not initiate live payment or activate campaigns.

### Package 04 — Tax and supplier-settlement release
- Convert only reviewed tax candidate migrations into ordered production packages.
- Verify source normalization, duplicate prevention, concurrency guards, effective dates and tax calculation basis.
- Review supplier disbursement evidence and withholding-tax treatment.
- Preserve Super Admin final settlement authorization.

### Package 05 — Command Centre and frontend consolidation
- Reconcile the production portal, Super Admin Command Center and four departmental mini-centres.
- Preserve existing account, customer, supplier, quotation, advertising and financial workflows.
- Exclude test-only links, credentials, keys and environment settings.

### Package 06 — Controlled production release
- For each approved package: confirm a recoverable backup, review exact diff, confirm dependencies, obtain the specific deployment approval, apply once, record migration/deployment identifiers, and verify the resulting production state.
- Use the rollback package only where its preconditions are met; never use destructive rollback against populated production records.
- Close the release item only after the production change is evidenced.

## 5. Immediate next actions

1. Reconcile the bookkeeping migration-history/source mismatch and stale bookkeeping documentation; do not rerun the schema migration.
2. Prepare the bookkeeping page/register correction as a production PR, preserving the two posted journals.
3. Review the exact password-policy PR #17 diff for production integration.
4. Reconcile the tax and settlement candidate migrations against the production schema and migration history.
5. Prepare the four-department Command Centre frontend consolidation, excluding the conflicting PR #10 sign-in proposal.

## 6. Explicitly out of scope until separately authorized

- Production database changes or migration execution.
- Production frontend deployment or PR merge.
- Any payment initiation, campaign activation, supplier settlement or customer transaction.
- Employee invitations, appointments or account activation.
- Changes to production secrets, SMTP, domain or Resend configuration.
- Deletion, renaming or bulk migration of legacy roles or existing records.

**Status:** Master register prepared from the repository and read-only production/test snapshots on 27 November 2026. This is an integration-control document, not evidence that pending packages have been deployed.
