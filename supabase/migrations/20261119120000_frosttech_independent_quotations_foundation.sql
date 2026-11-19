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
    item_type text not null check (item_type in ('product', 'service', 'accessory', 'installation', 'other')),
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

alter table public.frosttech_direct_quotations
    add column if not exists prepayment_terms_accepted_at timestamptz,
    add column if not exists prepayment_terms_version text;

alter table public.frosttech_direct_quote_fee_payments
    add column if not exists authorization_url text;

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
revoke all on function public.frosttech_reject_direct_quote_snapshot_mutation() from public, anon, authenticated;
grant execute on function public.frosttech_reject_direct_quote_snapshot_mutation() to service_role;


-- Submit a direct quotation and create its one-time customer invitation in a
-- single transaction. The raw token is generated by the trusted Edge Function;
-- only its SHA-256 hash is stored here.
create or replace function public.frosttech_issue_direct_quotation(
    p_quote_id uuid,
    p_actor uuid,
    p_invite_token_hash text,
    p_invite_expires_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $issue$
declare
    v_role text;
    v_quote public.frosttech_direct_quotations%rowtype;
    v_snapshot jsonb;
    v_item_count integer;
    v_fee numeric(14,2);
    v_invite_id uuid;
begin
    if p_quote_id is null or p_actor is null
       or p_invite_token_hash is null
       or length(p_invite_token_hash) <> 64
       or p_invite_token_hash !~ '^[0-9a-f]{64} is
    'Independent FrostTech quotations that do not require a quote_requests or customer_requests record.';
comment on table public.frosttech_direct_quote_fee_payments is
    'Separate Paystack administration-fee ledger for direct quotations before an order exists.';
comment on column public.orders.direct_quotation_id is
    'Optional link for orders created from independent FrostTech quotations; existing request-based links remain unchanged.';


-- Atomic draft creation. Only service_role can execute this routine; the
-- calling Edge Function must authenticate the user and verify admin_get_my_role.
create or replace function public.frosttech_create_direct_quotation_draft(
    p_header jsonb,
    p_items jsonb,
    p_actor uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $body$
declare
    v_role text;
    v_quote public.frosttech_direct_quotations%rowtype;
    v_item jsonb;
    v_line integer := 0;
    v_sum numeric(14,2) := 0;
    v_quantity numeric(14,3);
    v_unit_price numeric(14,2);
    v_line_total numeric(14,2);
    v_item_type text;
    v_product_id uuid;
    v_description text;
    v_unit text;
    v_subtotal numeric(14,2);
    v_additional numeric(14,2);
    v_discount numeric(14,2);
    v_delivery numeric(14,2);
    v_total numeric(14,2);
    v_customer_id uuid;
    v_email text;
begin
    if p_actor is null or p_header is null or jsonb_typeof(p_header) <> 'object'
       or p_items is null or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 100 then
        raise exception 'Invalid direct quotation draft payload';
    end if;

    select a.role into v_role
    from public.admin_accounts a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_actor
      and a.is_active is true
      and p.is_active is true
      and a.role in ('super_admin', 'operations_admin');

    if v_role is null then
        raise exception 'Super Administrator or Operations Administrator access is required';
    end if;

    v_email := lower(btrim(coalesce(p_header->>'customer_email', '')));
    if position('@' in v_email) <= 1 or position('.' in split_part(v_email, '@', 2)) <= 1 or position(' ' in v_email) > 0 then
                raise exception 'A valid customer email is required';
    end if;

    v_customer_id := nullif(p_header->>'customer_id', '')::uuid;
    if v_customer_id is not null and not exists (
        select 1 from public.customers c
        where c.id = v_customer_id
          and lower(btrim(coalesce(c.email, ''))) = v_email
    ) then
        raise exception 'Selected customer email does not match the registered customer';
    end if;

    v_subtotal := coalesce((p_header->>'subtotal')::numeric, -1);
    v_additional := coalesce((p_header->>'additional_charges')::numeric, -1);
    v_discount := coalesce((p_header->>'discount')::numeric, -1);
    v_delivery := coalesce((p_header->>'delivery_cost')::numeric, -1);

    if v_subtotal < 0 or v_additional < 0 or v_discount < 0 or v_delivery < 0
       or v_discount > v_subtotal + v_additional then
        raise exception 'Quotation amounts are invalid';
    end if;

    for v_item in select value from jsonb_array_elements(p_items)
    loop
        v_line := v_line + 1;
        v_item_type := lower(coalesce(v_item->>'item_type', ''));
        v_description := btrim(coalesce(v_item->>'description', ''));
        v_unit := btrim(coalesce(v_item->>'unit', 'unit'));
        v_quantity := (v_item->>'quantity')::numeric;
        v_unit_price := (v_item->>'unit_price')::numeric;
        v_line_total := (v_item->>'line_total')::numeric;
        v_product_id := nullif(v_item->>'product_id', '')::uuid;

        if v_item_type not in ('product', 'service', 'accessory', 'installation', 'other')
           or v_description = '' or length(v_description) > 500
           or v_unit = '' or length(v_unit) > 40
           or v_quantity <= 0 or v_quantity > 1000000
           or v_unit_price < 0
           or v_line_total <> round(v_quantity * v_unit_price, 2) then
            raise exception 'Quotation item % is invalid', v_line;
        end if;

        if v_item_type = 'product' then
            if v_product_id is null or not exists (
                select 1 from public.products p
                where p.id = v_product_id and p.is_active is true
            ) then
                raise exception 'Active catalogue product required for item %', v_line;
            end if;
        elsif v_product_id is not null then
            raise exception 'Non-product item cannot reference a catalogue product';
        end if;

        v_sum := v_sum + v_line_total;
        if v_sum > 1000000000 then
            raise exception 'Quotation subtotal exceeds the permitted limit';
        end if;
    end loop;

    if v_sum <> v_subtotal then
        raise exception 'Quotation item totals do not equal the submitted subtotal';
    end if;

    v_total := round(v_subtotal + v_additional - v_discount + v_delivery, 2);

    insert into public.frosttech_direct_quotations (
        customer_id, customer_name, customer_email, customer_phone,
        status, environment, subtotal, additional_charges, discount,
        delivery_cost, administration_fee, total_amount, fee_status,
        validity_expires_at, customer_message, internal_note, created_by
    ) values (
        v_customer_id,
        btrim(coalesce(p_header->>'customer_name', '')),
        v_email,
        nullif(btrim(coalesce(p_header->>'customer_phone', '')), ''),
        'draft',
        'development',
        v_subtotal, v_additional, v_discount, v_delivery, 0, v_total,
        'not_due',
        nullif(p_header->>'validity_expires_at', '')::timestamptz,
        nullif(p_header->>'customer_message', ''),
        nullif(p_header->>'internal_note', ''),
        p_actor
    )
    returning * into v_quote;

    v_line := 0;
    for v_item in select value from jsonb_array_elements(p_items)
    loop
        v_line := v_line + 1;
        insert into public.frosttech_direct_quotation_items (
            direct_quotation_id, line_number, item_type, product_id,
            description, quantity, unit, unit_price, line_total
        ) values (
            v_quote.id,
            v_line,
            lower(v_item->>'item_type'),
            nullif(v_item->>'product_id', '')::uuid,
            btrim(v_item->>'description'),
            (v_item->>'quantity')::numeric,
            coalesce(nullif(btrim(v_item->>'unit'), ''), 'unit'),
            (v_item->>'unit_price')::numeric,
            (v_item->>'line_total')::numeric
        );
    end loop;

    insert into public.admin_activity_log (
        actor_user_id, action, target_user_id, details
    ) values (
        p_actor,
        'direct_quotation_draft_created',
        null,
        jsonb_build_object(
            'direct_quotation_id', v_quote.id,
            'quotation_number', v_quote.quotation_number,
            'customer_email', v_email,
            'item_count', v_line,
            'environment', v_quote.environment
        )
    );

    return jsonb_build_object(
        'id', v_quote.id,
        'quotation_number', v_quote.quotation_number,
        'status', v_quote.status,
        'subtotal', v_quote.subtotal,
        'additional_charges', v_quote.additional_charges,
        'discount', v_quote.discount,
        'delivery_cost', v_quote.delivery_cost,
        'total_amount', v_quote.total_amount,
        'environment', v_quote.environment,
        'item_count', v_line
    );
end;
$body$;

revoke all on function public.frosttech_create_direct_quotation_draft(jsonb, jsonb, uuid)
    from public, anon, authenticated;
grant execute on function public.frosttech_create_direct_quotation_draft(jsonb, jsonb, uuid)
    to service_role;

commit;

       or p_invite_expires_at <= now()
       or p_invite_expires_at > now() + interval '30 days' then
        raise exception 'Invalid quotation invitation parameters';
    end if;

    select a.role into v_role
    from public.admin_accounts a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_actor
      and a.is_active is true
      and p.is_active is true
      and a.role in ('super_admin', 'operations_admin');

    if v_role is null then
        raise exception 'Super Administrator or Operations Administrator access is required';
    end if;

    select * into v_quote
    from public.frosttech_direct_quotations
    where id = p_quote_id
      and created_by = p_actor
    for update;

    if not found or v_quote.status <> 'draft' then
        raise exception 'Only your own saved draft can be issued';
    end if;

    if v_quote.validity_expires_at is not null
       and v_quote.validity_expires_at <= now() then
        raise exception 'Quotation validity date has already passed';
    end if;

    select count(*), coalesce(sum(i.line_total), 0)
      into v_item_count, v_fee
    from public.frosttech_direct_quotation_items i
    where i.direct_quotation_id = p_quote_id;

    if v_item_count < 1 or v_item_count > 100 or v_fee <> v_quote.subtotal then
        raise exception 'Quotation items no longer match the saved subtotal';
    end if;

    -- 2% of subtotal + additional charges - discount. Delivery is excluded.
    v_fee := round(
        (v_quote.subtotal + v_quote.additional_charges - v_quote.discount) * 0.02,
        2
    );

    update public.frosttech_direct_quotations
    set status = 'submitted',
        submitted_at = now(),
        administration_fee = v_fee,
        fee_status = case when v_fee > 0 then 'pending' else 'waived' end,
        updated_at = now()
    where id = p_quote_id
    returning * into v_quote;

    select jsonb_build_object(
        'quotation', to_jsonb(v_quote),
        'items', coalesce(
            jsonb_agg(to_jsonb(i) order by i.line_number),
            '[]'::jsonb
        )
    )
    into v_snapshot
    from public.frosttech_direct_quotation_items i
    where i.direct_quotation_id = p_quote_id;

    insert into public.frosttech_direct_quotation_snapshots (
        direct_quotation_id, version_number, approved_snapshot, captured_by
    ) values (
        p_quote_id, 1, coalesce(v_snapshot, '{}'::jsonb), p_actor
    );

    insert into public.frosttech_direct_quotation_invites (
        direct_quotation_id, email_normalized, token_hash,
        expires_at, created_by
    ) values (
        p_quote_id, lower(btrim(v_quote.customer_email)),
        p_invite_token_hash, p_invite_expires_at, p_actor
    )
    returning id into v_invite_id;

    insert into public.admin_activity_log (
        actor_user_id, action, target_user_id, details
    ) values (
        p_actor,
        'direct_quotation_issued',
        null,
        jsonb_build_object(
            'direct_quotation_id', p_quote_id,
            'quotation_number', v_quote.quotation_number,
            'invitation_id', v_invite_id,
            'administration_fee', v_fee,
            'fee_basis', 'subtotal + additional charges - discount; delivery excluded'
        )
    );

    return jsonb_build_object(
        'quotation_id', p_quote_id,
        'quotation_number', v_quote.quotation_number,
        'status', 'submitted',
        'administration_fee', v_fee,
        'fee_status', case when v_fee > 0 then 'pending' else 'waived' end,
        'invitation_id', v_invite_id,
        'invitation_expires_at', p_invite_expires_at
    );
end;
$issue$;

revoke all on function public.frosttech_issue_direct_quotation(uuid, uuid, text, timestamptz)
    from public, anon, authenticated;
grant execute on function public.frosttech_issue_direct_quotation(uuid, uuid, text, timestamptz)
    to service_role;


-- Claim a one-time invitation only after the signed-in customer's email and
-- active FrostTech customer profile have been verified by the database.
create or replace function public.frosttech_claim_direct_quote_invitation(
    p_token_hash text,
    p_actor uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $claim$
declare
    v_email text;
    v_profile_role text;
    v_profile_active boolean;
    v_invite public.frosttech_direct_quotation_invites%rowtype;
    v_quote public.frosttech_direct_quotations%rowtype;
    v_items jsonb;
    v_unlocked boolean;
begin
    if p_actor is null or p_token_hash is null
       or length(p_token_hash) <> 64
       or p_token_hash !~ '^[0-9a-f]{64} is
    'Independent FrostTech quotations that do not require a quote_requests or customer_requests record.';
comment on table public.frosttech_direct_quote_fee_payments is
    'Separate Paystack administration-fee ledger for direct quotations before an order exists.';
comment on column public.orders.direct_quotation_id is
    'Optional link for orders created from independent FrostTech quotations; existing request-based links remain unchanged.';


-- Atomic draft creation. Only service_role can execute this routine; the
-- calling Edge Function must authenticate the user and verify admin_get_my_role.
create or replace function public.frosttech_create_direct_quotation_draft(
    p_header jsonb,
    p_items jsonb,
    p_actor uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $body$
declare
    v_role text;
    v_quote public.frosttech_direct_quotations%rowtype;
    v_item jsonb;
    v_line integer := 0;
    v_sum numeric(14,2) := 0;
    v_quantity numeric(14,3);
    v_unit_price numeric(14,2);
    v_line_total numeric(14,2);
    v_item_type text;
    v_product_id uuid;
    v_description text;
    v_unit text;
    v_subtotal numeric(14,2);
    v_additional numeric(14,2);
    v_discount numeric(14,2);
    v_delivery numeric(14,2);
    v_total numeric(14,2);
    v_customer_id uuid;
    v_email text;
begin
    if p_actor is null or p_header is null or jsonb_typeof(p_header) <> 'object'
       or p_items is null or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 100 then
        raise exception 'Invalid direct quotation draft payload';
    end if;

    select a.role into v_role
    from public.admin_accounts a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_actor
      and a.is_active is true
      and p.is_active is true
      and a.role in ('super_admin', 'operations_admin');

    if v_role is null then
        raise exception 'Super Administrator or Operations Administrator access is required';
    end if;

    v_email := lower(btrim(coalesce(p_header->>'customer_email', '')));
    if position('@' in v_email) <= 1 or position('.' in split_part(v_email, '@', 2)) <= 1 or position(' ' in v_email) > 0 then
                raise exception 'A valid customer email is required';
    end if;

    v_customer_id := nullif(p_header->>'customer_id', '')::uuid;
    if v_customer_id is not null and not exists (
        select 1 from public.customers c
        where c.id = v_customer_id
          and lower(btrim(coalesce(c.email, ''))) = v_email
    ) then
        raise exception 'Selected customer email does not match the registered customer';
    end if;

    v_subtotal := coalesce((p_header->>'subtotal')::numeric, -1);
    v_additional := coalesce((p_header->>'additional_charges')::numeric, -1);
    v_discount := coalesce((p_header->>'discount')::numeric, -1);
    v_delivery := coalesce((p_header->>'delivery_cost')::numeric, -1);

    if v_subtotal < 0 or v_additional < 0 or v_discount < 0 or v_delivery < 0
       or v_discount > v_subtotal + v_additional then
        raise exception 'Quotation amounts are invalid';
    end if;

    for v_item in select value from jsonb_array_elements(p_items)
    loop
        v_line := v_line + 1;
        v_item_type := lower(coalesce(v_item->>'item_type', ''));
        v_description := btrim(coalesce(v_item->>'description', ''));
        v_unit := btrim(coalesce(v_item->>'unit', 'unit'));
        v_quantity := (v_item->>'quantity')::numeric;
        v_unit_price := (v_item->>'unit_price')::numeric;
        v_line_total := (v_item->>'line_total')::numeric;
        v_product_id := nullif(v_item->>'product_id', '')::uuid;

        if v_item_type not in ('product', 'service', 'accessory', 'installation', 'other')
           or v_description = '' or length(v_description) > 500
           or v_unit = '' or length(v_unit) > 40
           or v_quantity <= 0 or v_quantity > 1000000
           or v_unit_price < 0
           or v_line_total <> round(v_quantity * v_unit_price, 2) then
            raise exception 'Quotation item % is invalid', v_line;
        end if;

        if v_item_type = 'product' then
            if v_product_id is null or not exists (
                select 1 from public.products p
                where p.id = v_product_id and p.is_active is true
            ) then
                raise exception 'Active catalogue product required for item %', v_line;
            end if;
        elsif v_product_id is not null then
            raise exception 'Non-product item cannot reference a catalogue product';
        end if;

        v_sum := v_sum + v_line_total;
        if v_sum > 1000000000 then
            raise exception 'Quotation subtotal exceeds the permitted limit';
        end if;
    end loop;

    if v_sum <> v_subtotal then
        raise exception 'Quotation item totals do not equal the submitted subtotal';
    end if;

    v_total := round(v_subtotal + v_additional - v_discount + v_delivery, 2);

    insert into public.frosttech_direct_quotations (
        customer_id, customer_name, customer_email, customer_phone,
        status, environment, subtotal, additional_charges, discount,
        delivery_cost, administration_fee, total_amount, fee_status,
        validity_expires_at, customer_message, internal_note, created_by
    ) values (
        v_customer_id,
        btrim(coalesce(p_header->>'customer_name', '')),
        v_email,
        nullif(btrim(coalesce(p_header->>'customer_phone', '')), ''),
        'draft',
        'development',
        v_subtotal, v_additional, v_discount, v_delivery, 0, v_total,
        'not_due',
        nullif(p_header->>'validity_expires_at', '')::timestamptz,
        nullif(p_header->>'customer_message', ''),
        nullif(p_header->>'internal_note', ''),
        p_actor
    )
    returning * into v_quote;

    v_line := 0;
    for v_item in select value from jsonb_array_elements(p_items)
    loop
        v_line := v_line + 1;
        insert into public.frosttech_direct_quotation_items (
            direct_quotation_id, line_number, item_type, product_id,
            description, quantity, unit, unit_price, line_total
        ) values (
            v_quote.id,
            v_line,
            lower(v_item->>'item_type'),
            nullif(v_item->>'product_id', '')::uuid,
            btrim(v_item->>'description'),
            (v_item->>'quantity')::numeric,
            coalesce(nullif(btrim(v_item->>'unit'), ''), 'unit'),
            (v_item->>'unit_price')::numeric,
            (v_item->>'line_total')::numeric
        );
    end loop;

    insert into public.admin_activity_log (
        actor_user_id, action, target_user_id, details
    ) values (
        p_actor,
        'direct_quotation_draft_created',
        null,
        jsonb_build_object(
            'direct_quotation_id', v_quote.id,
            'quotation_number', v_quote.quotation_number,
            'customer_email', v_email,
            'item_count', v_line,
            'environment', v_quote.environment
        )
    );

    return jsonb_build_object(
        'id', v_quote.id,
        'quotation_number', v_quote.quotation_number,
        'status', v_quote.status,
        'subtotal', v_quote.subtotal,
        'additional_charges', v_quote.additional_charges,
        'discount', v_quote.discount,
        'delivery_cost', v_quote.delivery_cost,
        'total_amount', v_quote.total_amount,
        'environment', v_quote.environment,
        'item_count', v_line
    );
end;
$body$;

revoke all on function public.frosttech_create_direct_quotation_draft(jsonb, jsonb, uuid)
    from public, anon, authenticated;
grant execute on function public.frosttech_create_direct_quotation_draft(jsonb, jsonb, uuid)
    to service_role;

commit;
 then
        raise exception 'Invalid invitation';
    end if;

    select lower(btrim(u.email)) into v_email
    from auth.users u
    where u.id = p_actor and u.email_confirmed_at is not null;

    if v_email is null then
        raise exception 'A confirmed customer email address is required';
    end if;

    select p.role, p.is_active into v_profile_role, v_profile_active
    from public.profiles p
    where p.id = p_actor;

    if v_profile_role <> 'customer' or v_profile_active is not true then
        raise exception 'An active FrostTech customer account is required';
    end if;

    select * into v_invite
    from public.frosttech_direct_quotation_invites i
    where i.token_hash = p_token_hash
    for update;

    if not found
       or (v_invite.expires_at <= now() and v_invite.claimed_by is null)
       or v_invite.revoked_at is not null
       or v_invite.used_at is not null
       or v_invite.email_normalized <> v_email then
        raise exception 'Invitation is invalid, expired, or does not match your confirmed email';
    end if;

    if v_invite.claimed_by is not null and v_invite.claimed_by <> p_actor then
        raise exception 'This invitation has already been claimed by another account';
    end if;

    if v_invite.claimed_by is null then
        update public.frosttech_direct_quotation_invites
        set claimed_by = p_actor, claimed_at = now()
        where id = v_invite.id;
    end if;

    select * into v_quote
    from public.frosttech_direct_quotations q
    where q.id = v_invite.direct_quotation_id;

    if not found or v_quote.status not in ('submitted','accepted') then
        raise exception 'The quotation is no longer available';
    end if;

    if v_quote.validity_expires_at is not null and v_quote.validity_expires_at <= now()
       and v_quote.status = 'submitted' then
        raise exception 'This quotation has expired';
    end if;

    v_unlocked := v_quote.fee_status in ('paid','waived');

    if v_unlocked then
        select coalesce(jsonb_agg(to_jsonb(i) order by i.line_number),'[]'::jsonb)
        into v_items
        from public.frosttech_direct_quotation_items i
        where i.direct_quotation_id = v_quote.id;
    else
        v_items := '[]'::jsonb;
    end if;

    return jsonb_build_object(
        'quotation_id',v_quote.id,
        'quotation_number',v_quote.quotation_number,
        'customer_name',v_quote.customer_name,
        'status',v_quote.status,
        'currency',v_quote.currency,
        'administration_fee',v_quote.administration_fee,
        'fee_status',v_quote.fee_status,
        'total_amount',case when v_unlocked then v_quote.total_amount else null end,
        'subtotal',case when v_unlocked then v_quote.subtotal else null end,
        'additional_charges',case when v_unlocked then v_quote.additional_charges else null end,
        'discount',case when v_unlocked then v_quote.discount else null end,
        'delivery_cost',case when v_unlocked then v_quote.delivery_cost else null end,
        'customer_message',case when v_unlocked then v_quote.customer_message else null end,
        'validity_expires_at',v_quote.validity_expires_at,
        'details_unlocked',v_unlocked,
        'items',v_items
    );
end;
$claim$;

revoke all on function public.frosttech_claim_direct_quote_invitation(text, uuid)
    from public, anon, authenticated;
grant execute on function public.frosttech_claim_direct_quote_invitation(text, uuid)
    to service_role;


-- Atomically record a verified Paystack administration-fee success.
create or replace function public.frosttech_record_direct_quote_fee_success(
    p_quote_id uuid,
    p_payment_id uuid,
    p_actor uuid,
    p_reference text,
    p_provider_transaction_id text,
    p_verified_at timestamptz,
    p_verification_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $fee$
declare
    v_quote public.frosttech_direct_quotations%rowtype;
    v_payment public.frosttech_direct_quote_fee_payments%rowtype;
begin
    if p_actor is null or not exists (
        select 1 from public.profiles p
        where p.id=p_actor and p.role='customer' and p.is_active is true
    ) then
        raise exception 'Active customer account required';
    end if;

    select * into v_quote
    from public.frosttech_direct_quotations
    where id=p_quote_id
    for update;
    if not found then raise exception 'Direct quotation not found'; end if;

    select * into v_payment
    from public.frosttech_direct_quote_fee_payments
    where id=p_payment_id
      and direct_quotation_id=p_quote_id
      and provider_reference=p_reference
    for update;
    if not found then raise exception 'Fee payment attempt not found'; end if;

    if v_payment.status='successful' then
        if v_quote.fee_status <> 'paid' then
            update public.frosttech_direct_quotations
            set fee_status='paid',updated_at=now()
            where id=p_quote_id;
        end if;
        return jsonb_build_object('success',true,'already_recorded',true);
    end if;

    if v_payment.status <> 'pending'
       or v_payment.environment <> v_quote.environment
       or v_payment.amount <> v_quote.administration_fee
       or v_quote.fee_status <> 'pending' then
        raise exception 'Fee payment no longer matches the quotation';
    end if;

    update public.frosttech_direct_quote_fee_payments
    set status='successful',
        provider_transaction_id=p_provider_transaction_id,
        verified_at=coalesce(p_verified_at,now()),
        verification_payload=coalesce(p_verification_payload,'{}'::jsonb),
        updated_at=now()
    where id=p_payment_id;

    update public.frosttech_direct_quotations
    set fee_status='paid',updated_at=now()
    where id=p_quote_id;

    insert into public.admin_activity_log (
        actor_user_id,action,target_user_id,details
    ) values (
        p_actor,
        'direct_quotation_admin_fee_paid',
        null,
        jsonb_build_object(
            'direct_quotation_id',p_quote_id,
            'fee_payment_id',p_payment_id,
            'provider_reference',p_reference,
            'amount',v_payment.amount,
            'environment',v_payment.environment
        )
    );

    return jsonb_build_object('success',true,'already_recorded',false);
end;
$fee$;

revoke all on function public.frosttech_record_direct_quote_fee_success(uuid, uuid, uuid, text, text, timestamptz, jsonb)
    from public, anon, authenticated;
grant execute on function public.frosttech_record_direct_quote_fee_success(uuid, uuid, text, text, timestamptz, jsonb)
    to service_role;

comment on table public.frosttech_direct_quotations is
    'Independent FrostTech quotations that do not require a quote_requests or customer_requests record.';
comment on table public.frosttech_direct_quote_fee_payments is
    'Separate Paystack administration-fee ledger for direct quotations before an order exists.';
comment on column public.orders.direct_quotation_id is
    'Optional link for orders created from independent FrostTech quotations; existing request-based links remain unchanged.';


-- Atomic draft creation. Only service_role can execute this routine; the
-- calling Edge Function must authenticate the user and verify admin_get_my_role.
create or replace function public.frosttech_create_direct_quotation_draft(
    p_header jsonb,
    p_items jsonb,
    p_actor uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $body$
declare
    v_role text;
    v_quote public.frosttech_direct_quotations%rowtype;
    v_item jsonb;
    v_line integer := 0;
    v_sum numeric(14,2) := 0;
    v_quantity numeric(14,3);
    v_unit_price numeric(14,2);
    v_line_total numeric(14,2);
    v_item_type text;
    v_product_id uuid;
    v_description text;
    v_unit text;
    v_subtotal numeric(14,2);
    v_additional numeric(14,2);
    v_discount numeric(14,2);
    v_delivery numeric(14,2);
    v_total numeric(14,2);
    v_customer_id uuid;
    v_email text;
begin
    if p_actor is null or p_header is null or jsonb_typeof(p_header) <> 'object'
       or p_items is null or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 100 then
        raise exception 'Invalid direct quotation draft payload';
    end if;

    select a.role into v_role
    from public.admin_accounts a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_actor
      and a.is_active is true
      and p.is_active is true
      and a.role in ('super_admin', 'operations_admin');

    if v_role is null then
        raise exception 'Super Administrator or Operations Administrator access is required';
    end if;

    v_email := lower(btrim(coalesce(p_header->>'customer_email', '')));
    if position('@' in v_email) <= 1 or position('.' in split_part(v_email, '@', 2)) <= 1 or position(' ' in v_email) > 0 then
                raise exception 'A valid customer email is required';
    end if;

    v_customer_id := nullif(p_header->>'customer_id', '')::uuid;
    if v_customer_id is not null and not exists (
        select 1 from public.customers c
        where c.id = v_customer_id
          and lower(btrim(coalesce(c.email, ''))) = v_email
    ) then
        raise exception 'Selected customer email does not match the registered customer';
    end if;

    v_subtotal := coalesce((p_header->>'subtotal')::numeric, -1);
    v_additional := coalesce((p_header->>'additional_charges')::numeric, -1);
    v_discount := coalesce((p_header->>'discount')::numeric, -1);
    v_delivery := coalesce((p_header->>'delivery_cost')::numeric, -1);

    if v_subtotal < 0 or v_additional < 0 or v_discount < 0 or v_delivery < 0
       or v_discount > v_subtotal + v_additional then
        raise exception 'Quotation amounts are invalid';
    end if;

    for v_item in select value from jsonb_array_elements(p_items)
    loop
        v_line := v_line + 1;
        v_item_type := lower(coalesce(v_item->>'item_type', ''));
        v_description := btrim(coalesce(v_item->>'description', ''));
        v_unit := btrim(coalesce(v_item->>'unit', 'unit'));
        v_quantity := (v_item->>'quantity')::numeric;
        v_unit_price := (v_item->>'unit_price')::numeric;
        v_line_total := (v_item->>'line_total')::numeric;
        v_product_id := nullif(v_item->>'product_id', '')::uuid;

        if v_item_type not in ('product', 'service', 'accessory', 'installation', 'other')
           or v_description = '' or length(v_description) > 500
           or v_unit = '' or length(v_unit) > 40
           or v_quantity <= 0 or v_quantity > 1000000
           or v_unit_price < 0
           or v_line_total <> round(v_quantity * v_unit_price, 2) then
            raise exception 'Quotation item % is invalid', v_line;
        end if;

        if v_item_type = 'product' then
            if v_product_id is null or not exists (
                select 1 from public.products p
                where p.id = v_product_id and p.is_active is true
            ) then
                raise exception 'Active catalogue product required for item %', v_line;
            end if;
        elsif v_product_id is not null then
            raise exception 'Non-product item cannot reference a catalogue product';
        end if;

        v_sum := v_sum + v_line_total;
        if v_sum > 1000000000 then
            raise exception 'Quotation subtotal exceeds the permitted limit';
        end if;
    end loop;

    if v_sum <> v_subtotal then
        raise exception 'Quotation item totals do not equal the submitted subtotal';
    end if;

    v_total := round(v_subtotal + v_additional - v_discount + v_delivery, 2);

    insert into public.frosttech_direct_quotations (
        customer_id, customer_name, customer_email, customer_phone,
        status, environment, subtotal, additional_charges, discount,
        delivery_cost, administration_fee, total_amount, fee_status,
        validity_expires_at, customer_message, internal_note, created_by
    ) values (
        v_customer_id,
        btrim(coalesce(p_header->>'customer_name', '')),
        v_email,
        nullif(btrim(coalesce(p_header->>'customer_phone', '')), ''),
        'draft',
        'development',
        v_subtotal, v_additional, v_discount, v_delivery, 0, v_total,
        'not_due',
        nullif(p_header->>'validity_expires_at', '')::timestamptz,
        nullif(p_header->>'customer_message', ''),
        nullif(p_header->>'internal_note', ''),
        p_actor
    )
    returning * into v_quote;

    v_line := 0;
    for v_item in select value from jsonb_array_elements(p_items)
    loop
        v_line := v_line + 1;
        insert into public.frosttech_direct_quotation_items (
            direct_quotation_id, line_number, item_type, product_id,
            description, quantity, unit, unit_price, line_total
        ) values (
            v_quote.id,
            v_line,
            lower(v_item->>'item_type'),
            nullif(v_item->>'product_id', '')::uuid,
            btrim(v_item->>'description'),
            (v_item->>'quantity')::numeric,
            coalesce(nullif(btrim(v_item->>'unit'), ''), 'unit'),
            (v_item->>'unit_price')::numeric,
            (v_item->>'line_total')::numeric
        );
    end loop;

    insert into public.admin_activity_log (
        actor_user_id, action, target_user_id, details
    ) values (
        p_actor,
        'direct_quotation_draft_created',
        null,
        jsonb_build_object(
            'direct_quotation_id', v_quote.id,
            'quotation_number', v_quote.quotation_number,
            'customer_email', v_email,
            'item_count', v_line,
            'environment', v_quote.environment
        )
    );

    return jsonb_build_object(
        'id', v_quote.id,
        'quotation_number', v_quote.quotation_number,
        'status', v_quote.status,
        'subtotal', v_quote.subtotal,
        'additional_charges', v_quote.additional_charges,
        'discount', v_quote.discount,
        'delivery_cost', v_quote.delivery_cost,
        'total_amount', v_quote.total_amount,
        'environment', v_quote.environment,
        'item_count', v_line
    );
end;
$body$;

revoke all on function public.frosttech_create_direct_quotation_draft(jsonb, jsonb, uuid)
    from public, anon, authenticated;
grant execute on function public.frosttech_create_direct_quotation_draft(jsonb, jsonb, uuid)
    to service_role;

commit;
