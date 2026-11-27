# FrostTech Authentication Password Policy

## Scope
This change adds a shared browser-side password policy to customer registration, advertiser registration, customer password reset, advertiser password reset, and supplier password reset. It does not alter sign-in validation, Supabase Auth configuration, existing passwords, accounts, sessions, or database records.

Employee invitation/password setup is intentionally excluded while FrostTech employment remains paused.

## Policy
- New passwords must contain at least 12 Unicode characters.
- Maximum accepted password size is 72 UTF-8 bytes, matching the Supabase Auth bcrypt limit.
- Spaces and passphrases are allowed; no arbitrary uppercase, digit, or symbol composition rule is imposed.
- Password confirmation must match wherever the form has a confirmation field.
- Passwords consisting only of whitespace are rejected.
- The browser gives inline guidance and blocks submission before the existing Supabase sign-up/update handler runs.

This is a frontend guard. Supabase Auth remains the authoritative validator and continues to enforce its configured server-side requirements. This change does not enable leaked-password screening.

## Regression checklist
1. 8-character password: blocked with the 12-character guidance.
2. 11-character password: blocked.
3. 12-character passphrase with spaces: accepted by the client validator.
4. 12-character password with mixed case, digits, and symbols: accepted.
5. Confirmation mismatch: blocked.
6. Matching confirmation: accepted.
7. Password exceeding 72 UTF-8 bytes: blocked with the Supabase size-limit message.
8. Whitespace-only password: blocked.
9. Customer and advertiser sign-in: unchanged; no new minimum is imposed on existing login passwords.
10. Reset email requests, redirect URLs, recovery-session checks, and Supabase update calls: unchanged.
11. Employee invitation setup: unchanged and not enabled by this work.

## Deployment status
Prepared on the isolated Git branch `security/password-policy-hardening`. It has not been merged into `main` and has not been deployed to GitHub Pages or applied to Supabase.
