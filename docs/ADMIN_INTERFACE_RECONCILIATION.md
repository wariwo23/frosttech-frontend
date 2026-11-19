# FrostTech Administration Interface Reconciliation — Review Draft

## Scope and safety

This branch is a review-only preparation. It does not change production Supabase, execute migrations, invite employees, create employee records, deploy GitHub Pages, or alter the `main` branch. No paid services, plans, branches, or add-ons are required.

## Read-only findings from `main`

The current repository contains four overlapping administration pages:

| Page | Observed responsibility |
|---|---|
| `admin.html` | Main Super Admin dashboard; includes employee registration, onboarding records, invitations, employment activation, and administrator account listing/actions. |
| `employee-management.html` | Separate employee registration/onboarding interface; calls employee-management RPCs independently. |
| `admin-management.html` | Separate administrator appointment, status/removal, and activity-log interface. Its employee lookup uses `admin_find_employee_for_appointment`. |
| `department-operator-management.html` | Department/operator assignment and administrator access interface; merged previously in PR #11. |

The main dashboard's employee form calls `admin_create_frosttech_employee`. It explicitly tells the Super Admin that creating a record does not send an invitation or grant administrator access. The existing onboarding workflow is therefore not to be recreated.

## Recommended target responsibilities

1. **`admin.html` — employee register and onboarding source of truth**
   - Register employee records.
   - View onboarding status.
   - Send invitations.
   - Track password/account setup.
   - Activate employment after setup.
   - Keep the existing employee creation and invitation safeguards.

2. **`department-operator-management.html` — departmental access control**
   - Assign/reassign an employee's department where permitted.
   - Appoint departmental administrator access based on the registered department.
   - Suspend/reactivate/remove departmental administrator access.
   - Protect the permanent Super Administrator account.
   - Retain server-side authorization and audit logging.

3. **Activity log**
   - Preserve the existing audit-log capability and ensure there is one clearly signposted place to review it.
   - Do not remove the existing `admin_list_activity_log` path until its consumers and data coverage have been checked.

4. **Legacy pages**
   - Keep `employee-management.html` and `admin-management.html` available during the transition.
   - Do not redirect, delete, or disable them until their complete RPC dependencies, direct links, and any existing user bookmarks have been checked.
   - After parity is proven, replace duplicate interfaces with clear links to the canonical workspaces rather than maintaining competing write paths.

## Required safeguards before source-page consolidation

- Compare all RPCs used by the four pages with the deployed function signatures and authorization checks.
- Confirm the employee list, invitation status, account-setup status, and activation state are represented consistently.
- Confirm only the Super Administrator can create employee records, assign/reassign departments, and appoint/suspend/reactivate/remove departmental administrator access.
- Preserve the permanent Super Administrator and all current customer, guest, supplier, and supplier-cost permissions.
- Preserve existing login, session, password-reset, redirect, and invitation acceptance behaviour.
- Add fresh Super Administrator password verification before sensitive actions only after validating a safe reauthentication flow that does not unexpectedly sign out or disrupt the active session.
- Ensure confirmation/action failures remain visible to the operator; do not close the modal in a way that hides an error.
- Verify audit events for every sensitive administrative action.

## Database migration boundary

The migration `supabase/migrations/20261118160000_super_admin_department_reassignment.sql` is already merged to `main` from PR #11 but has **not** been executed. This review does not execute it. Department reassignment must not be described as live until the migration has been separately approved, executed, and verified.

## Validation plan (free/local/read-only where possible)

1. Static review of page links, form handlers, RPC names/arguments, role checks, and redirects.
2. Check JavaScript syntax without connecting to or mutating production services.
3. Review the proposed diff in GitHub before any merge.
4. After separate approval, conduct a controlled end-to-end test using a test employee only if no-cost test facilities are available; do not create invitations or records during this preparation.
5. Keep deployment and production migration as separate, explicit approval steps.

## Implementation prepared on the review branch

The following frontend changes have now been prepared on `review/admin-interface-reconciliation`:

- `admin.html` remains the canonical employee registration and onboarding workspace. It retains employee creation, invitation, account-setup visibility and employment activation. Departmental appointment and account-access controls have been moved out of this page; it now links to the dedicated department workspace.
- `department-operator-management.html` remains the canonical departmental appointment and access-control workspace. An explicit Sign Out action and a link to the activity log were added.
- Department reassignment is visibly disabled in this review build because its supporting migration is merged but has not been executed in Supabase. The UI explains that the feature remains unavailable until separately approved, executed and verified.
- `admin-management.html` is now a read-only administrator activity-log page. Duplicate employee appointment and account-access mutation controls were removed. Hardcoded personal name and CEO title were removed; the signed-in identity is obtained from the authenticated session.
- `employee-management.html` is retained as a legacy landing page with links to the canonical employee and department workspaces. It no longer provides a second employee registration/invitation interface.

## Validation and known limits

- The changes are isolated to this review branch and do not affect `main`.
- No Supabase SQL, migration, employee record, invitation, role change, or production data was executed or changed.
- No production deployment was performed.
- No paid plans, branches, add-ons, or external services were used.
- The branch has not been subjected to a live end-to-end test because that would require using authenticated production actions and could create or modify real records.
- Before merge, review the full diff and perform static JavaScript/HTML checks. Any test involving employee creation, invitations, activation, role changes or access status must use a separately approved no-cost test environment.
- Fresh password reauthentication before sensitive actions remains a recommended follow-up. It must be implemented with a verified session-safe approach; do not use a naive `signInWithPassword` call that could replace or disrupt the active session.
- Confirm that the current deployed RPC signatures and Edge Function response shape match the retained frontend calls before merging.

## Current status

- Review branch: `review/admin-interface-reconciliation`.
- Draft PR #12 contains the implementation changes for review.
- Production `main`, Supabase schema/data and GitHub Pages deployment remain unchanged.
