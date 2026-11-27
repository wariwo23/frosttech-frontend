-- Isolated test-only alignment for quotation authorization regression tests.
-- Production schema is already expected to contain this private snapshot table.

begin;

create table if not exists public.admin_quotation_pricing_snapshots (
  quotation_id uuid primary key references public.admin_quotations(id) on delete cascade,
  pricing_snapshot jsonb not null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_quotation_pricing_snapshots_object_check
    check (jsonb_typeof(pricing_snapshot)='object')
);

alter table public.admin_quotation_pricing_snapshots enable row level security;
alter table public.admin_quotation_pricing_snapshots force row level security;
grant select,insert,update on public.admin_quotation_pricing_snapshots to authenticated;

insert into public.admin_role_permissions(role,permission)
values ('operations_admin','quotations.manage')
on conflict do nothing;

insert into public.admin_role_permissions(role,permission)
values ('finance_admin','quotations.read_financial')
on conflict do nothing;

commit;
