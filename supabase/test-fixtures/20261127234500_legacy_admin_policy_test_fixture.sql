-- Isolated-only fixtures for legacy administrator-policy retirement.
-- Creates only missing test tables; no production schema is touched.

begin;

create table if not exists public.admin_controls (
 id uuid primary key default gen_random_uuid(),
 control_key text not null,
 control_value text,
 description text,
 updated_at timestamptz not null default now()
);
alter table public.admin_controls enable row level security;
grant select,insert,update,delete on public.admin_controls to anon,authenticated;

create table if not exists public.customer_requests (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid,
 request_number text,
 title text not null,
 description text,
 category text,
 quantity integer not null default 1,
 preferred_brand text,
 budget numeric,
 delivery_address text,
 status text not null default 'pending',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 source_quote_request_id uuid
);
alter table public.customer_requests enable row level security;
grant select,insert,update,delete on public.customer_requests to anon,authenticated;

create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid,
 title text not null,
 message text not null,
 type text,
 reference_type text,
 reference_id uuid,
 is_read boolean not null default false,
 created_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
grant select,insert,update,delete on public.notifications to anon,authenticated;

create table if not exists public.order_quotation_snapshots (
 order_id uuid not null,
 quotation_id uuid not null,
 version_group_id uuid not null,
 version_number integer not null,
 approved_snapshot jsonb not null,
 captured_at timestamptz not null default now()
);
alter table public.order_quotation_snapshots enable row level security;
grant select,insert,update,delete on public.order_quotation_snapshots to anon,authenticated;

commit;
