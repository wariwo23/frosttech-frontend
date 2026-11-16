-- FrostTech Guest Registration Intent
-- Review and apply only as part of the separate Guest journey deployment.
-- This table stores only a short-lived registration proof; never store passwords here.
create table if not exists public.guest_registration_intents (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  full_name text not null,
  phone text not null,
  registration_token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  auth_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists guest_registration_intents_email_created_idx
  on public.guest_registration_intents (lower(email), created_at desc);
alter table public.guest_registration_intents enable row level security;
revoke all on table public.guest_registration_intents from public, anon, authenticated;
grant all on table public.guest_registration_intents to service_role;
comment on table public.guest_registration_intents is
  'Private short-lived proof that a FrostTech Guest registration was initiated through the dedicated guest registration flow. Never exposes password data.';