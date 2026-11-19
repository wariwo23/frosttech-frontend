# FrostTech Independent Quotations — Draft Implementation Contract

**Status:** Review-only implementation stage 1. No migration has been executed and no production code has been deployed.

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
- Drafts are forced to the development environment and are not emailed, submitted, fee-charged, accepted, or converted to orders.

## Remaining server-side workflows before the feature is usable

1. **Create/update draft:** initial draft creation and draft listing are implemented; draft editing is still outstanding. Never expose supplier cost.
2. **Submit quotation:** lock draft; validate item sum, discount, validity and environment; calculate the direct-quotation fee using the invariant above; issue the quotation number and secure customer invitation; record audit event.
3. **Invite/claim:** generate a cryptographically random token; persist only a cryptographic hash; send the raw token once; enforce expiry, one-time use, email match and authenticated account ownership. Do not permit anonymous acceptance or create duplicate customer accounts.
4. **Customer retrieval/decision:** authenticated customer may see only quotations bound to their verified account or a successfully claimed invitation. Accept/decline must be atomic and idempotent. Decline reason must be validated if required by the existing customer decision experience.
5. **Accept/create order:** in one trusted server transaction, lock the quotation, verify ownership, claim, submitted state, paid/waived fee and explicit Terms acceptance; create one order, order items and immutable snapshot; link `orders.direct_quotation_id`. Never fabricate a `quote_requests` or `customer_requests` row.
6. **Fee payment:** initialize Paystack only from server-calculated amount and the quotation's stored environment. Verify provider reference, success, NGN currency and exact amount from Paystack's server response. Make retries idempotent.
7. **Order payment/delivery:** reuse the existing order-payment and delivery safeguards only after confirming they support a direct quotation's null request links. Preserve the order environment trigger: production order creation must occur through trusted server/service-role execution. Delivery remains subject to existing eligible product categories and duplicate protection.

## Security and preservation

- New tables have RLS enabled and no browser-role policies. Browser roles receive no direct table privileges; Edge Functions must authenticate callers and enforce ownership/department permissions before using service-role access.
- The migration does not modify existing request-based quotation tables, existing customer policies, supplier-cost RPCs, existing payment functions, existing delivery rules, or existing customer records.
- Super Admin remains protected. Department operators must be checked against their assigned department on every privileged operation.
- Invitation tokens, Paystack secrets, and supplier costs must never be sent to the browser or stored in plaintext.
- Snapshot rows are append-only.
- No migration, Edge Function deployment, live payment, invitation email, or production order has been performed.

## Remaining implementation and verification

This migration is a database foundation, **not a complete customer-facing feature**. Before the draft can be considered ready to merge, implement the server functions and admin/customer interfaces above, add automated tests for authorization, amount tampering, expired/replayed invitations, concurrent acceptance, duplicate payment callbacks and duplicate order creation, and verify the existing payment functions can process a direct order without request linkage. Keep all changes in this review branch until separately approved.
