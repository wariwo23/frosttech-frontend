# FrostTech Authentication Password Policy

## Scope
A shared browser-side password policy is included on:
- Customer registration
- Supplier registration
- Guest registration
- Advertiser registration
- Customer password reset
- Supplier password reset
- Advertiser password reset

Existing sign-in fields are not subject to the new-password rule. Employee invitation/password setup is intentionally excluded while FrostTech employment remains paused.

## Policy
- New passwords must contain at least 12 Unicode characters.
- Maximum accepted password size is 72 UTF-8 bytes, matching the Supabase Auth bcrypt password limit.
- Spaces and passphrases are allowed; no arbitrary uppercase, digit, or symbol composition rule is imposed.
- Password confirmation must match wherever the form has a confirmation field.
- Passwords consisting only of whitespace are rejected.
- The browser provides inline guidance and blocks invalid form submission before existing registration or Supabase password-update handlers run.

This is a frontend guard. It is not a substitute for server-side Auth enforcement; Supabase Auth remains authoritative and continues to enforce its configured server-side requirements. No Auth settings were changed and leaked-password screening remains unavailable on the current Free plan.

## Verification completed
- 9 password-validator regression cases.
- 12 authentication page integration/compatibility cases.
- 16 DOM-level cases using the actual HTML forms and shared validator through jsdom.
- GitHub Actions run for commit `b8621e9ae00b4fd634fb9822ef138e4ebb6c6dba`: **37 tests passed, 0 failed**.

The DOM tests verify short-password blocking, valid passphrase acceptance, confirmation mismatch feedback, and the 72-byte limit across the relevant forms. They do not constitute a manual test in a full graphical browser or a live Supabase email-delivery test.

## Not changed
- Existing passwords, accounts, sessions, or user records.
- Supabase Auth configuration, database, Edge Functions, or SMTP/Brevo settings.
- Existing login rules or password-reset email destinations.
- Employee onboarding and appointments.

## Deployment status
Prepared on the isolated Git branch `security/password-policy-hardening` and tracked in Draft Pull Request #17. It has not been merged into `main`, deployed to GitHub Pages, or applied to Supabase. Manual graphical-browser verification and a separately approved test recovery-email delivery remain outstanding.
