-- FrostTech independent customer quotations: additive foundation only.
-- Review branch: review/direct-customer-quotations
-- This migration has NOT been executed. It deliberately leaves all existing
-- request-based quotation, order, payment, and authorization functions unchanged.

begin;

create sequence if not exists public.frosttech_direct_quote_number_seq
    as bigint
    start with 1
    increment by 1
    no cycle;

create table if not exists public.frosttech_direct_quotations (
    id uuid primary key default gen_random_uuid(),
    quotation_number text not null unique
        default (
            'FT-DQ-' || to_char(clock_timestamp(), 'YYYY') || '-' ||
            lpad(nextval('public.frosttech_direct_quote_number_seq')::text, 7, '0')
        ),
    customer_id uuid null references public.customers(id) on delete set null,
    customer_name text not null,
    customer_email text not null,
    customer_phone text,
    currency text not null default 'NGN' check (currency = 'NGN'),
    status text not null default 'draft'
        check (status in ('draft', 'submitted', 'accepted', 'declined', 'expired', 'cancelled')),
    environment text not null default 'development'
        check (environment in ('development', 'production')),
    subtotal numeric(14,2) not null default 0 check (subtotal >= 0),
    additional_charges numeric(14,2) not null default 0 check (additional_charges >= 0),
    discount numeric(14,2) not null default 0 check (discount >= 0),
    delivery_cost numeric(14,2) not null default 0 check (delivery_cost >= 0),
    administration_fee numeric(14,2) not null default 0 check (administration_fee >= 0),
    total_amount numeric(14,2) not null default 0 check (total_amount >= 0),
    fee_status text not null default 'not_due'
        check (fee_status in ('not_due', 'pending', 'paid', 'failed', 'waived')),
    validity_expires_at timestamptz,
    customer_message text,
    internal_note text,
    created_by uuid not null references auth.users(id) on delete restrict,
    submitted_at timestamptz,
    decision_at timestamptz,
    accepted_by uuid references auth.users(id) on delete set null,
    declined_reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (discount <= subtotal + additional_charges),
    check (
        total_amount =
        round(subtotal + additional_charges - discount + delivery_cost, 2)
    ),
    check (
        (status = 'draft' and submitted_at is null and decision_at is null)
        or status <> 'draft'
    ),
    check (
        status <> 'accepted'
        or (decision_at is not null and accepted_by is not null)
    ),
    check (
        status <> 'declined'
        or decision_at is not null
    )
);

create table if not exists public.frosttech_direct_quotation_items (
    id uuid primary key default gen_random_uuid(),
    direct_quotation_id uuid not null
        references public.frosttech_direct_quotations(id) on delete restrict,
    line_number integer not null check (line_number > 0),
    item_type text not null check (item_type in ('product', 'service', 'other')),
    product_id uuid references public.products(id) on delete set null,
    description text not null,
    quantity numeric(14,3) not null check (quantity > 0),
    unit text not null default 'unit',
    unit_price numeric(14,2) not null check (unit_price >= 0),
    line_total numeric(14,2) not null check (line_total >= 0),
    created_at timestamptz not null default now(),
    unique (direct_quotation_id, line_number),
    check (line_total = round(quantity * unit_price, 2)),
    check ((item_type = 'product' and product_id is not null) or item_type <> 'product')
);

create table if not exists public.frosttech_direct_quotation_invites (
    id uuid primary key default gen_random_uuid(),
    direct_quotation_id uuid not null
        references public.frosttech_direct_quotations(id) on delete restrict,
    email_normalized text not null,
    token_hash text not null unique,
    expires_at timestamptz not null,
    claimed_by uuid references auth.users(id) on delete set null,
    claimed_at timestamptz,
    used_at timestamptz,
    revoked_at timestamptz,
    created_by uuid not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now(),
    check (email_normalized = lower(btrim(email_normalized))),
    check (claimed_at is null or claimed_by is not null)
);

create table if not exists public.frosttech_direct_quote_fee_payments (
    id uuid primary key default gen_random_uuid(),
    direct_quotation_id uuid not null
        references public.frosttech_direct_quotations(id) on delete restrict,
    amount numeric(14,2) not null check (amount > 0),
    currency text not null default 'NGN' check (currency = 'NGN'),
    provider text not null default 'paystack' check (provider = 'paystack'),
    provider_reference text not null unique,
    idempotency_key text not null unique,
    status text not null default 'pending'
        check (status in ('pending', 'successful', 'failed', 'refunded')),
    environment text not null check (environment in ('development', 'production')),
    provider_transaction_id text,
    verified_at timestamptz,
    verification_payload jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists frosttech_direct_quote_one_pending_fee_idx
    on public.frosttech_direct_quote_fee_payments(direct_quotation_id)
    where status = 'pending';

create table if not exists public.frosttech_direct_quotation_snapshots (
    id uuid primary key default gen_random_uuid(),
    direct_quotation_id uuid not null
        references public.frosttech_direct_quotations(id) on delete restrict,
    version_number integer not null check (version_number > 0),
    approved_snapshot jsonb not null,
    captured_at timestamptz not null default now(),
    captured_by uuid references auth.users(id) on delete set null,
    unique (direct_quotation_id, version_number)
);

-- Orders retain their existing request/quotation links. This nullable link is
-- populated only by the new trusted direct-quotation acceptance path.
alter table public.orders
    add column if not exists direct_quotation_id uuid;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.orders'::regclass
          and conname = 'orders_direct_quotation_id_fkey'
    ) then
        alter table public.orders
            add constraint orders_direct_quotation_id_fkey
            foreign key (direct_quotation_id)
            references public.frosttech_direct_quotations(id)
            on delete restrict;
    end if;
end
$$;

create unique index if not exists orders_one_per_direct_quotation_idx
    on public.orders(direct_quotation_id)
    where direct_quotation_id is not null;

create index if not exists frosttech_direct_quotations_customer_idx
    on public.frosttech_direct_quotations(customer_id, created_at desc);
create index if not exists frosttech_direct_quotations_email_idx
    on public.frosttech_direct_quotations(lower(customer_email), created_at desc);
create index if not exists frosttech_direct_quotations_status_idx
    on public.frosttech_direct_quotations(status, created_at desc);
create index if not exists frosttech_direct_items_quote_idx
    on public.frosttech_direct_quotation_items(direct_quotation_id, line_number);
create index if not exists frosttech_direct_invites_quote_idx
    on public.frosttech_direct_quotation_invites(direct_quotation_id, created_at desc);
create index if not exists frosttech_direct_invites_claim_idx
    on public.frosttech_direct_quotation_invites(email_normalized, expires_at)
    where claimed_at is null and used_at is null and revoked_at is null;
create index if not exists frosttech_direct_fee_quote_idx
    on public.frosttech_direct_quote_fee_payments(direct_quotation_id, created_at desc);
create index if not exists frosttech_direct_snapshots_quote_idx
    on public.frosttech_direct_quotation_snapshots(direct_quotation_id, version_number desc);

-- Snapshot rows are append-only, including for service_role. A later
-- correction must create a new version, never rewrite an accepted snapshot.
create or replace function public.frosttech_reject_direct_quote_snapshot_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    raise exception 'FrostTech quotation snapshots are immutable';
end;
$$;

drop trigger if exists frosttech_direct_quote_snapshot_immutable
    on public.frosttech_direct_quotation_snapshots;
create trigger frosttech_direct_quote_snapshot_immutable
    before update or delete on public.frosttech_direct_quotation_snapshots
    for each row execute function public.frosttech_reject_direct_quote_snapshot_mutation();

-- No browser role receives direct table access. New Edge Functions must use
-- service_role only after authenticating the caller and enforcing ownership,
-- department permissions, invitation claims, and status transitions.
alter table public.frosttech_direct_quotations enable row level security;
alter table public.frosttech_direct_quotation_items enable row level security;
alter table public.frosttech_direct_quotation_invites enable row level security;
alter table public.frosttech_direct_quote_fee_payments enable row level security;
alter table public.frosttech_direct_quotation_snapshots enable row level security;

revoke all on public.frosttech_direct_quotations from anon, authenticated;
revoke all on public.frosttech_direct_quotation_items from anon, authenticated;
revoke all on public.frosttech_direct_quotation_invites from anon, authenticated;
revoke all on public.frosttech_direct_quote_fee_payments from anon, authenticated;
revoke all on public.frosttech_direct_quotation_snapshots from anon, authenticated;
revoke all on sequence public.frosttech_direct_quote_number_seq from anon, authenticated;

grant all on public.frosttech_direct_quotations to service_role;
grant all on public.frosttech_direct_quotation_items to service_role;
grant all on public.frosttech_direct_quotation_invites to service_role;
grant all on public.frosttech_direct_quote_fee_payments to service_role;
grant select, insert on public.frosttech_direct_quotation_snapshots to service_role;
grant usage, select on sequence public.frosttech_direct_quote_number_seq to service_role;
grant execute on function public.frosttech_reject_direct_quote_snapshot_mutation() to service_role;

comment on table public.frosttech_direct_quotations is
    'Independent FrostTech quotations that do not require a quote_requests or customer_requests record.';
comment on table public.frosttech_direct_quote_fee_payments is
    'Separate Paystack administration-fee ledger for direct quotations before an order exists.';
comment on column public.orders.direct_quotation_id is
    'Optional link for orders created from independent FrostTech quotations; existing request-based links remain unchanged.';

commit;
