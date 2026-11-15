# FrostTech Notification Recovery (review draft)

This branch contains an implementation draft only. It has not been deployed and its SQL has not been applied.

## Files
- `supabase/migrations/20261115000100_frosttech_notification_recovery.sql`
- `supabase/functions/admin-notification-recovery/index.ts`
- `supabase/functions/send-frosttech-notification/index.ts` — proposed compatible sender update to record provider HTTP status and distinguish unknown network outcomes.
- `admin.html` — adds the Notification Centre workspace and controlled recovery dialog.

## Security and behavior
- Recovery Edge Function must be deployed with JWT verification enabled (`verify_jwt: true`).
- The function validates the bearer token with Supabase Auth; every database RPC independently requires `is_super_admin()`.
- Public sender claim RPC may claim only pending, never-attempted events. Failed and stale-sending events cannot be reclaimed by the public workflow.
- Recovery accepts only failed events, requires explicit confirmation and a reason, locks the event, preserves its event key/recipient/payload, and writes start/result audit entries to `admin_activity_log`.
- Recovery is hard-disabled unless the server-side secret `FROSTTECH_EMAIL_RECOVERY_DOMAIN_READY=true` is explicitly configured after the user releases the sending-domain hold. No such secret has been set.
- Only definitive provider 401/403 authorization failures are eligible after configuration is corrected; network/unknown outcomes and other status codes remain blocked.
- Viewing records does not send email. A retry requires an explicit action from the Notification Centre.
- The recovery function reconstructs the original event-specific subject and message from the saved event key/payload; it does not accept a replacement recipient or payload from the browser.
- If provider acceptance cannot be recorded, the endpoint returns an uncertain outcome. Do not retry until reconciled.

## Outstanding review before deployment
- Run static TypeScript/Deno checks and validate the migration against a staging copy.
- Confirm the deployed Edge Function has `verify_jwt: true`.
- Configure `FROSTTECH_EMAIL_RECOVERY_DOMAIN_READY=true` only after the sending domain is verified and the user explicitly releases the hold.
- Recovery uses a distinct idempotency key per confirmed retry attempt; verify this behavior against Resend's idempotency policy in staging.
- Verify the existing public notification sender's CORS and claim behavior against the migration in staging.
- Test the dashboard with a Super Administrator session and a non-admin session. Do not use real customer email addresses for tests.

## Apply/deploy status
Not applied. Not deployed. No customer email sent. No changes made to the live main branch.
