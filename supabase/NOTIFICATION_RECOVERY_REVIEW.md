# FrostTech Notification Recovery (review draft)

This branch contains an implementation draft only. It has not been deployed and its SQL has not been applied.

## Files
- `supabase/migrations/20261115000100_frosttech_notification_recovery.sql`
- `supabase/functions/admin-notification-recovery/index.ts`

## Security and behavior
- Requires a valid Supabase user session; all RPCs independently require `is_super_admin()`.
- Public sender claim RPC may claim only pending, never-attempted events. Failed and stale-sending events cannot be reclaimed by the public workflow.
- Recovery accepts only failed events, requires explicit confirmation and a reason, locks the event, preserves its event key/recipient/payload, and writes start/result audit entries to `admin_activity_log`.
- Current known Resend 403 test-mode/unverified-domain failures are deliberately blocked. The sender domain/DNS hold is not altered.
- No email is sent merely by viewing the list. Recovery requires an explicit user-triggered `action: "recover"` request.
- If provider acceptance cannot be recorded, the endpoint returns an uncertain outcome and must not be retried until reconciled.

## Important review blocker
The sender currently creates route-specific HTML and subjects in `send-frosttech-notification`. This recovery draft currently sends a generic notification body. Before deployment, recovery must reproduce the original event-specific content exactly. The draft is therefore intentionally NOT production-ready.

## Apply/deploy status
Not applied. Not deployed. No customer email sent.
