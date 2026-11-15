# FrostTech Notification Recovery (review draft)

This branch contains an implementation draft only. It has not been deployed and its SQL has not been applied.

## Files
- `supabase/migrations/20261115000100_frosttech_notification_recovery.sql`
- `supabase/functions/admin-notification-recovery/index.ts`
- `admin.html` — adds the Notification Centre workspace and controlled recovery dialog.

## Security and behavior
- Recovery Edge Function must be deployed with JWT verification enabled (`verify_jwt: true`).
- The function validates the bearer token with Supabase Auth; every database RPC independently requires `is_super_admin()`.
- Public sender claim RPC may claim only pending, never-attempted events. Failed and stale-sending events cannot be reclaimed by the public workflow.
- Recovery accepts only failed events, requires explicit confirmation and a reason, locks the event, preserves its event key/recipient/payload, and writes start/result audit entries to `admin_activity_log`.
- Current known Resend 403 test-mode/unverified-domain failures are deliberately blocked. The sender domain/DNS hold is not altered.
- Viewing records does not send email. A retry requires an explicit action from the Notification Centre.
- The recovery function reconstructs the original event-specific subject and message from the saved event key/payload; it does not accept a replacement recipient or payload from the browser.
- If provider acceptance cannot be recorded, the endpoint returns an uncertain outcome. Do not retry until reconciled.

## Outstanding review before deployment
- Run static TypeScript/Deno checks and validate the migration against a staging copy.
- Confirm the deployed Edge Function has `verify_jwt: true`.
- Review whether the existing Resend idempotency key can safely be reused for manual recovery after the provider's idempotency retention window.
- Verify the existing public notification sender's CORS and claim behavior against the migration in staging.
- Test the dashboard with a Super Administrator session and a non-admin session. Do not use real customer email addresses for tests.

## Apply/deploy status
Not applied. Not deployed. No customer email sent. No changes made to the live main branch.
