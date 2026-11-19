# FrostTech Independent Quotations — Draft Implementation Contract

**Status:** Review-only implementation stage 3. No migration has been executed and no production code has been deployed.

## Scope

Add a second quotation origin: a FrostTech-created quotation that is not attached to a customer request. Existing request-based quotations remain on their current tables and functions.

The additive database foundation is in:

`supabase/migrations/20261119120000_frosttech_independent_quotations_foundation.sql`

## Data model

- `frosttech_direct_quotations`: quotation header, customer contact, lifecycle, amounts, validity and environment.
- `frosttech_direct_quotation_items`: independent line items. The existing `admin_quotation_items` table is deliberately not reused because its scope-immutability trigger is tied to request-based quotation behavior.
- `frosttech_direct_quotation_invites`: one-time, expiring invitation claims. Only a token hash is stored; raw invitation tokens must never be persisted.
- `frosttech_direct_quote_fee_payments`: separate pre-order administration-fee ledger. Existing `payments.order_id` is required, so it is not suitable for a fee payment before an order exists.
- `frosttech_direct_quotation_snapshots`: append-only snapshots.
- `orders.direct_quotation_id`: nullable additive link; a unique index prevents more than one order per direct quotation.

## Financial invariants

- Quotation total: `subtotal + additional_charges - discount + delivery_cost`.
- Administration fee: preserve the approved existing rule: **2% × (subtotal + additional charges − discount)**. Delivery is excluded entirely.
- Do not alter the existing request-based fee calculation or its working payment functions.
- Final order payment must equal the accepted quotation total; do not recalculate or silently alter the customer-approved amount.
- Amounts and payment references must be calculated/verified server-side, never trusted from browser input.

## Implemented in this review branch

- `create-direct-quotation` Edge Function authenticates the operator, verifies `admin_get_my_role`, and supports listing that operator's own drafts.
- The function validates customer details, active catalogue product references, item quantities and prices, and sends the normalized draft to the atomic database routine.
- `frosttech_create_direct_quotation_draft` checks the actor's active Super Admin/Operations role again, recomputes and checks item totals, creates header and line items in one transaction, and records an activity-log event.
- `admin-independent-quotations.html` provides the responsive draft-entry workspace and saved-draft list. The existing admin quotation workspace links to it without changing its request-based workflow.
- Drafts are forced to the development environment. They can now be issued through a separate authenticated function; issuance snapshots the quotation, calculates the approved fee, creates a one-time invitation hash and sends the invitation using the existing Resend configuration when available. If email delivery is unavailable, the authorised operator receives the secure link for controlled sharing.
- Customers can claim the invitation only after signing in with a confirmed email matching the invited address and an active FrostTech customer profile.
- Customer quotation details remain locked until the separate direct-quotation administration fee is verified as paid or waived.
- A separate Paystack Test Mode fee flow now records Terms acceptance server-side, reserves one pending payment attempt, verifies the exact reference/status/NGN amount, and records success atomically. The existing request-based Paystack functions remain unchanged.
- The customer invitation page provides the sign-in/registration return path and displays quotation details only after the fee is settled.
- Customers can accept or decline the issued quotation. Acceptance requires explicit confirmation and creates one direct order atomically; decline requires a reason and creates no order.
- A customer record is linked or created only after the verified customer accepts; no duplicate Auth account or synthetic customer request is created.
- Accepted orders retain an immutable quotation/order snapshot, preserve the accepted total and delivery amount, and start in `awaiting_payment`.
- A separate final-order Paystack Test Mode flow requires a fresh Terms acceptance, verifies the exact order amount and reference, updates the existing `payments` record and order atomically, and requests the existing FrostTech receipt workflow.
- Delivery processing reuses the existing conservative helper and is not run for development/Test Mode payments.

## Remaining server-side workflows before the feature is usable

1. **Create/update draft:** initial draft creation and draft listing are implemented; draft editing is still outstanding. Never expose supplier cost.
2. **Submit quotation:** implemented for saved drafts. The issue routine locks the draft, validates item sum and validity, calculates the fee using the invariant above, captures an immutable snapshot and stores only the invitation token hash.
3. **Invite/claim:** implemented for first claim. A cryptographically random token is generated; only SHA-256 hash is stored; the email is sent through the existing Resend setup where configured; claims require a confirmed email match and an active customer account. Reissue/revocation management remains outstanding.
4. **Customer retrieval/decision:** authenticated invitation claim, fee-gated quotation display, accept/decline, decline reason and atomic idempotency are implemented.
5. **Accept/create order:** implemented in one trusted server transaction. The customer, invitation, quote status, paid/waived fee and explicit acceptance are checked; one order, order items and immutable snapshot are created; `orders.direct_quotation_id` is linked. No `quote_requests` or `customer_requests` row is fabricated.
6. **Fee payment:** isolated direct-quotation fee initialization, verification and receipt processing are implemented for development/Test Mode only. They use the stored server-calculated fee, require Terms acceptance, and verify Paystack reference, success, NGN currency and exact amount. Live-mode enablement and retry/reconciliation administration remain outstanding.
7. **Order payment/delivery:** isolated final-order payment initialization, fresh Terms acceptance, Paystack verification, order status update and receipt processing are implemented for Test Mode. Delivery uses the existing conservative helper and is intentionally not created for Test Mode payments. Production enablement remains outstanding.

## Security and preservation

- New tables have RLS enabled and no browser-role policies. Browser roles receive no direct table privileges; Edge Functions must authenticate callers and enforce ownership/department permissions before using service-role access.
- The migration does not modify existing request-based quotation tables, existing customer policies, supplier-cost RPCs, existing payment functions, existing delivery rules, or existing customer records.
- Super Admin remains protected. Department operators must be checked against their assigned department on every privileged operation.
- Invitation tokens, Paystack secrets, and supplier costs must never be sent to the browser or stored in plaintext.
- Snapshot rows are append-only.
- No migration, Edge Function deployment, live payment, invitation email, or production order has been performed.

## Remaining implementation and verification

This migration and code are still **review-only**. Draft editing, comprehensive automated tests, concurrency/replay tests, browser verification, and controlled end-to-end Test Mode testing remain outstanding. Confirm the email provider configuration and receipt delivery in Test Mode. Keep all changes in this review branch until separately approved.
