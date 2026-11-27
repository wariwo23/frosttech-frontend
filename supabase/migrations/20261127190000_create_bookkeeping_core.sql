-- FrostTech Bookkeeping Core — production integration candidate
-- Reconstructed from live isolated-test catalog and reviewed against production.
-- No-cost isolated-schema PostgreSQL rehearsal passed on 2026-11-27.
-- Additive production foundation: creates only the 12 ft_bookkeeping_* tables,
-- their indexes, constraints, RLS policies, internal guards and audit triggers.
-- It does not alter existing production tables, functions, policies, storage,
-- tax settings, admin assignments, or financial records.
-- No test data, opening balances, chart-of-accounts seeds, or accounting periods are imported.
-- Existing production tax/finance objects and authorization helper functions are not modified.

begin;

do $$
declare
  v_existing text;
begin
  select string_agg(format('%I', c.relname), ', ')
    into v_existing
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r','p')
    and c.relname = any (array[
      'ft_bookkeeping_accounts',
      'ft_bookkeeping_audit_log',
      'ft_bookkeeping_bank_accounts',
      'ft_bookkeeping_bank_transactions',
      'ft_bookkeeping_documents',
      'ft_bookkeeping_expenses',
      'ft_bookkeeping_fixed_assets',
      'ft_bookkeeping_journal_lines',
      'ft_bookkeeping_journals',
      'ft_bookkeeping_periods',
      'ft_bookkeeping_reconciliations',
      'ft_bookkeeping_shareholder_loans'
    ]);
  if v_existing is not null then
    raise exception 'Bookkeeping migration stopped: target table(s) already exist: %', v_existing;
  end if;
end $$;

-- 1. Independent reference tables.
create table public.ft_bookkeeping_accounts (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  account_type text not null check (account_type in ('asset','liability','equity','income','expense')),
  parent_id uuid references public.ft_bookkeeping_accounts(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

create table public.ft_bookkeeping_audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id uuid,
  action text not null,
  actor_id uuid references auth.users(id),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.ft_bookkeeping_periods (
  id uuid primary key default gen_random_uuid(),
  period_name text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'open' check (status in ('open','closed')),
  closed_at timestamptz,
  closed_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_periods_dates_check check (end_date >= start_date),
  unique (start_date, end_date)
);

-- 2. Journals are created before their dependent line and expense tables.
create table public.ft_bookkeeping_journals (
  id uuid primary key default gen_random_uuid(),
  entry_number bigint generated always as identity unique,
  entry_date date not null,
  description text not null,
  source_type text not null default 'manual',
  source_reference text,
  period_id uuid references public.ft_bookkeeping_periods(id),
  status text not null default 'draft'
    check (status in ('draft','submitted','approved','posted','rejected')),
  prepared_by uuid references auth.users(id),
  submitted_at timestamptz,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ft_bookkeeping_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  account_name text not null,
  bank_name text not null,
  account_number_last4 text,
  currency char(3) not null default 'NGN',
  ledger_account_id uuid references public.ft_bookkeeping_accounts(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.ft_bookkeeping_journal_lines (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.ft_bookkeeping_journals(id) on delete restrict,
  account_id uuid not null references public.ft_bookkeeping_accounts(id) on delete restrict,
  line_description text,
  debit numeric(18,2) not null default 0,
  credit numeric(18,2) not null default 0,
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_journal_lines_one_side_check
    check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  constraint ft_bookkeeping_journal_lines_debit_check check (debit >= 0),
  constraint ft_bookkeeping_journal_lines_credit_check check (credit >= 0)
);

create table public.ft_bookkeeping_bank_transactions (
  id uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references public.ft_bookkeeping_bank_accounts(id),
  transaction_date date not null,
  description text not null,
  reference text,
  debit numeric(18,2) not null default 0,
  credit numeric(18,2) not null default 0,
  source text not null default 'manual' check (source in ('manual','statement_import')),
  matched_journal_line_id uuid references public.ft_bookkeeping_journal_lines(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_bank_transactions_one_side_check
    check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  constraint ft_bookkeeping_bank_transactions_debit_check check (debit >= 0),
  constraint ft_bookkeeping_bank_transactions_credit_check check (credit >= 0)
);

create table public.ft_bookkeeping_documents (
  id uuid primary key default gen_random_uuid(),
  document_type text not null,
  document_name text not null,
  storage_path text,
  external_reference text,
  document_date date,
  related_table text,
  related_record_id uuid,
  notes text,
  uploaded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_documents_source_check
    check (storage_path is not null or external_reference is not null)
);

create table public.ft_bookkeeping_expenses (
  id uuid primary key default gen_random_uuid(),
  expense_date date not null,
  payee text not null,
  description text not null,
  account_id uuid not null references public.ft_bookkeeping_accounts(id),
  amount numeric(18,2) not null check (amount > 0),
  payment_method text,
  bank_transaction_id uuid references public.ft_bookkeeping_bank_transactions(id),
  journal_id uuid references public.ft_bookkeeping_journals(id),
  status text not null default 'draft'
    check (status in ('draft','submitted','approved','rejected')),
  prepared_by uuid references auth.users(id),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.ft_bookkeeping_fixed_assets (
  id uuid primary key default gen_random_uuid(),
  asset_name text not null,
  acquisition_date date not null,
  cost numeric(18,2) not null check (cost > 0),
  useful_life_months integer,
  residual_value numeric(18,2) not null default 0,
  depreciation_method text not null default 'straight_line',
  accumulated_depreciation numeric(18,2) not null default 0,
  status text not null default 'active' check (status in ('active','disposed','written_off')),
  journal_id uuid references public.ft_bookkeeping_journals(id),
  supporting_document_id uuid,
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_fixed_assets_residual_nonnegative_check check (residual_value >= 0),
  constraint ft_bookkeeping_fixed_assets_residual_limit_check check (residual_value <= cost),
  constraint ft_bookkeeping_fixed_assets_depreciation_nonnegative_check check (accumulated_depreciation >= 0),
  constraint ft_bookkeeping_fixed_assets_depreciation_limit_check
    check (accumulated_depreciation <= (cost - residual_value)),
  constraint ft_bookkeeping_fixed_assets_useful_life_check
    check (useful_life_months > 0)
);

create table public.ft_bookkeeping_reconciliations (
  id uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references public.ft_bookkeeping_bank_accounts(id),
  period_start date not null,
  period_end date not null,
  statement_closing_balance numeric(18,2) not null,
  ledger_closing_balance numeric(18,2) not null,
  difference numeric(18,2) generated always as (statement_closing_balance - ledger_closing_balance) stored,
  status text not null default 'draft' check (status in ('draft','submitted','approved')),
  prepared_by uuid references auth.users(id),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  supporting_document_id uuid,
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_reconciliations_period_check check (period_end >= period_start)
);

create table public.ft_bookkeeping_shareholder_loans (
  id uuid primary key default gen_random_uuid(),
  lender_name text not null,
  principal_amount numeric(18,2) not null check (principal_amount > 0),
  interest_rate numeric(7,4) not null default 0 check (interest_rate >= 0),
  repayment_terms text not null,
  agreement_date date,
  amount_repaid numeric(18,2) not null default 0,
  status text not null default 'outstanding'
    check (status in ('outstanding','partially_repaid','repaid')),
  journal_id uuid references public.ft_bookkeeping_journals(id),
  supporting_document_id uuid,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint ft_bookkeeping_shareholder_loans_repaid_nonnegative_check check (amount_repaid >= 0),
  constraint ft_bookkeeping_shareholder_loans_repaid_limit_check check (amount_repaid <= principal_amount)
);

-- 3. Workflow guard functions. Invoker security is intentional; authorization is
-- checked using production's existing Super Admin helper, not test-only grants.
create or replace function public.ft_bookkeeping_guard_journal()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_debits numeric(18,2);
  v_credits numeric(18,2);
  v_lines integer;
  v_period_start date;
  v_period_end date;
  v_period_status text;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'posted' then
      raise exception 'Posted journal entries are immutable. Use a separately approved reversal or adjustment entry.';
    end if;
    if old.status in ('submitted','approved') and not public.is_super_admin() then
      raise exception 'Submitted or approved journal entries cannot be changed by Finance Admin.';
    end if;
  end if;

  if new.status in ('approved','posted') and not public.is_super_admin() then
    raise exception 'Only the Super Administrator may approve or post journal entries.';
  end if;

  if tg_op = 'UPDATE' and old.status = 'submitted' and new.status not in ('submitted','approved','rejected') then
    raise exception 'A submitted journal can only remain submitted, be approved or be rejected.';
  end if;
  if tg_op = 'UPDATE' and old.status = 'approved' and new.status not in ('approved','posted') then
    raise exception 'An approved journal can only remain approved or be posted.';
  end if;

  if new.status = 'posted' then
    select count(*), coalesce(sum(debit),0), coalesce(sum(credit),0)
      into v_lines, v_debits, v_credits
    from public.ft_bookkeeping_journal_lines
    where journal_id = new.id;

    if v_lines < 2 or v_debits <= 0 or v_debits <> v_credits then
      raise exception 'Journal entry cannot be posted: at least two lines and equal non-zero debits and credits are required.';
    end if;

    if new.period_id is null then
      raise exception 'A journal must be assigned to an accounting period before posting.';
    end if;

    select start_date, end_date, status
      into v_period_start, v_period_end, v_period_status
    from public.ft_bookkeeping_periods where id = new.period_id;

    if not found or new.entry_date < v_period_start or new.entry_date > v_period_end then
      raise exception 'Journal date must fall within its assigned accounting period.';
    end if;
    if v_period_status <> 'open' then
      raise exception 'Journal entry cannot be posted into a closed accounting period.';
    end if;
    new.posted_by := auth.uid();
    new.posted_at := now();
  end if;

  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;

  new.updated_at := now();
  return new;
end;
$function$;

create or replace function public.ft_bookkeeping_guard_journal_line()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_old_status text;
  v_new_status text;
begin
  if tg_op in ('UPDATE','DELETE') then
    select status into v_old_status
    from public.ft_bookkeeping_journals
    where id = old.journal_id;

    if v_old_status in ('approved','posted') then
      raise exception 'Approved and posted journal lines are immutable.';
    end if;
    if v_old_status is distinct from 'draft' and not public.is_super_admin() then
      raise exception 'Journal lines are locked after submission. Return a submitted journal through the controlled review process before correction.';
    end if;
  end if;

  if tg_op in ('INSERT','UPDATE') then
    select status into v_new_status
    from public.ft_bookkeeping_journals
    where id = new.journal_id;

    if v_new_status in ('approved','posted') then
      raise exception 'Approved and posted journal lines are immutable.';
    end if;
    if v_new_status is distinct from 'draft' and not public.is_super_admin() then
      raise exception 'Journal lines may only be added to draft journals.';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$function$;

create trigger ft_bookkeeping_journal_guard
before insert or update on public.ft_bookkeeping_journals
for each row execute function public.ft_bookkeeping_guard_journal();

create trigger ft_bookkeeping_journal_line_guard
before insert or update or delete on public.ft_bookkeeping_journal_lines
for each row execute function public.ft_bookkeeping_guard_journal_line();

-- 3a. Append-only audit trail for journal headers and lines.
-- SECURITY DEFINER is restricted to trigger invocation; no browser RPC grant.
create or replace function public.ft_bookkeeping_capture_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_old jsonb;
  v_new jsonb;
  v_record_id uuid;
  v_action text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new);
    if tg_table_name = 'ft_bookkeeping_documents' then v_new := v_new - 'storage_path'; end if;
    v_record_id := new.id;
    v_action := 'INSERT';
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    if tg_table_name = 'ft_bookkeeping_documents' then
      v_old := v_old - 'storage_path';
      v_new := v_new - 'storage_path';
    end if;
    v_record_id := new.id;
    v_action := 'UPDATE';
  elsif tg_op = 'DELETE' then
    v_old := to_jsonb(old);
    if tg_table_name = 'ft_bookkeeping_documents' then v_old := v_old - 'storage_path'; end if;
    v_record_id := old.id;
    v_action := 'DELETE';
  else
    raise exception 'Unsupported audit trigger operation: %', tg_op;
  end if;

  insert into public.ft_bookkeeping_audit_log
    (table_name, record_id, action, actor_id, details, created_at)
  values
    (tg_table_name, v_record_id, v_action, auth.uid(),
     jsonb_build_object('old', v_old, 'new', v_new), now());

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$function$;

create or replace function public.ft_bookkeeping_reject_audit_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  raise exception 'Bookkeeping audit records are append-only and cannot be changed or deleted.';
end;
$function$;

create trigger ft_bookkeeping_journals_audit
after insert or update or delete on public.ft_bookkeeping_journals
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_accounts_audit
after insert or update or delete on public.ft_bookkeeping_accounts
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_bank_accounts_audit
after insert or update or delete on public.ft_bookkeeping_bank_accounts
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_bank_transactions_audit
after insert or update or delete on public.ft_bookkeeping_bank_transactions
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_documents_audit
after insert or update or delete on public.ft_bookkeeping_documents
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_expenses_audit
after insert or update or delete on public.ft_bookkeeping_expenses
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_fixed_assets_audit
after insert or update or delete on public.ft_bookkeeping_fixed_assets
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_periods_audit
after insert or update or delete on public.ft_bookkeeping_periods
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_reconciliations_audit
after insert or update or delete on public.ft_bookkeeping_reconciliations
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_shareholder_loans_audit
after insert or update or delete on public.ft_bookkeeping_shareholder_loans
for each row execute function public.ft_bookkeeping_capture_audit();


create trigger ft_bookkeeping_journal_lines_audit
after insert or update or delete on public.ft_bookkeeping_journal_lines
for each row execute function public.ft_bookkeeping_capture_audit();

create trigger ft_bookkeeping_audit_immutable
before update or delete on public.ft_bookkeeping_audit_log
for each row execute function public.ft_bookkeeping_reject_audit_mutation();

revoke all on function public.ft_bookkeeping_capture_audit() from public, anon, authenticated;
revoke all on function public.ft_bookkeeping_reject_audit_mutation() from public, anon, authenticated;

-- 4. RLS policies. No anonymous access. No test-only role fallback.
alter table public.ft_bookkeeping_accounts enable row level security;
alter table public.ft_bookkeeping_audit_log enable row level security;
alter table public.ft_bookkeeping_bank_accounts enable row level security;
alter table public.ft_bookkeeping_bank_transactions enable row level security;
alter table public.ft_bookkeeping_documents enable row level security;
alter table public.ft_bookkeeping_expenses enable row level security;
alter table public.ft_bookkeeping_fixed_assets enable row level security;
alter table public.ft_bookkeeping_journal_lines enable row level security;
alter table public.ft_bookkeeping_journals enable row level security;
alter table public.ft_bookkeeping_periods enable row level security;
alter table public.ft_bookkeeping_reconciliations enable row level security;
alter table public.ft_bookkeeping_shareholder_loans enable row level security;

create policy ft_bookkeeping_accounts_read on public.ft_bookkeeping_accounts
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_accounts_write on public.ft_bookkeeping_accounts
for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

create policy ft_bookkeeping_audit_read on public.ft_bookkeeping_audit_log
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));

create policy ft_bookkeeping_bank_accounts_read on public.ft_bookkeeping_bank_accounts
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_bank_accounts_write on public.ft_bookkeeping_bank_accounts
for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

create policy ft_bookkeeping_bank_tx_prepare on public.ft_bookkeeping_bank_transactions
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_bank_tx_read on public.ft_bookkeeping_bank_transactions
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_bank_tx_update on public.ft_bookkeeping_bank_transactions
for update to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

create policy ft_bookkeeping_documents_insert on public.ft_bookkeeping_documents
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.documents.manage'));
create policy ft_bookkeeping_documents_read on public.ft_bookkeeping_documents
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_documents_update on public.ft_bookkeeping_documents
for update to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

create policy ft_bookkeeping_expenses_insert on public.ft_bookkeeping_expenses
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_expenses_read on public.ft_bookkeeping_expenses
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_expenses_update on public.ft_bookkeeping_expenses
for update to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'))
with check (
  public.is_super_admin()
  or (
    public.admin_has_permission('bookkeeping.prepare')
    and status in ('draft','submitted','rejected')
  )
);

create policy ft_bookkeeping_assets_prepare on public.ft_bookkeeping_fixed_assets
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_assets_read on public.ft_bookkeeping_fixed_assets
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_assets_update on public.ft_bookkeeping_fixed_assets
for update to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

create policy ft_bookkeeping_lines_insert on public.ft_bookkeeping_journal_lines
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_lines_read on public.ft_bookkeeping_journal_lines
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_lines_update on public.ft_bookkeeping_journal_lines
for update to authenticated
using (
  public.is_super_admin()
  or (
    public.admin_has_permission('bookkeeping.prepare')
    and exists (
      select 1 from public.ft_bookkeeping_journals j
      where j.id = ft_bookkeeping_journal_lines.journal_id and j.status = 'draft'
    )
  )
)
with check (
  public.is_super_admin()
  or (
    public.admin_has_permission('bookkeeping.prepare')
    and exists (
      select 1 from public.ft_bookkeeping_journals j
      where j.id = ft_bookkeeping_journal_lines.journal_id and j.status = 'draft'
    )
  )
);

create policy ft_bookkeeping_journals_insert on public.ft_bookkeeping_journals
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_journals_read on public.ft_bookkeeping_journals
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_journals_update on public.ft_bookkeeping_journals
for update to authenticated
using (
  public.is_super_admin()
  or (public.admin_has_permission('bookkeeping.prepare') and status = 'draft')
)
with check (
  public.is_super_admin()
  or (
    public.admin_has_permission('bookkeeping.prepare')
    and status in ('draft','submitted')
  )
);

create policy ft_bookkeeping_periods_prepare on public.ft_bookkeeping_periods
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_periods_read on public.ft_bookkeeping_periods
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_periods_update on public.ft_bookkeeping_periods
for update to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

create policy ft_bookkeeping_reconciliations_insert on public.ft_bookkeeping_reconciliations
for insert to authenticated
with check (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'));
create policy ft_bookkeeping_reconciliations_read on public.ft_bookkeeping_reconciliations
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_reconciliations_update on public.ft_bookkeeping_reconciliations
for update to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.prepare'))
with check (
  public.is_super_admin()
  or (
    public.admin_has_permission('bookkeeping.prepare')
    and status in ('draft','submitted')
  )
);

create policy ft_bookkeeping_loans_read on public.ft_bookkeeping_shareholder_loans
for select to authenticated
using (public.is_super_admin() or public.admin_has_permission('bookkeeping.read'));
create policy ft_bookkeeping_loans_write on public.ft_bookkeeping_shareholder_loans
for all to authenticated
using (public.is_super_admin()) with check (public.is_super_admin());

-- 5. Explicit least-privilege Data API grants.
-- Match the inspected current frontend: six read tables, journal/line inserts,
-- and journal status updates. Do not grant writes for unused future controls.
revoke all on table
  public.ft_bookkeeping_accounts,
  public.ft_bookkeeping_audit_log,
  public.ft_bookkeeping_bank_accounts,
  public.ft_bookkeeping_bank_transactions,
  public.ft_bookkeeping_documents,
  public.ft_bookkeeping_expenses,
  public.ft_bookkeeping_fixed_assets,
  public.ft_bookkeeping_journal_lines,
  public.ft_bookkeeping_journals,
  public.ft_bookkeeping_periods,
  public.ft_bookkeeping_reconciliations,
  public.ft_bookkeeping_shareholder_loans
from public, anon, authenticated;

grant select on table
  public.ft_bookkeeping_accounts,
  public.ft_bookkeeping_audit_log,
  public.ft_bookkeeping_periods,
  public.ft_bookkeeping_journals,
  public.ft_bookkeeping_journal_lines,
  public.ft_bookkeeping_expenses,
  public.ft_bookkeeping_shareholder_loans
to authenticated;

grant insert on table
  public.ft_bookkeeping_journals,
  public.ft_bookkeeping_journal_lines
to authenticated;

grant update on table
  public.ft_bookkeeping_journals
to authenticated;

-- Trigger functions are internal implementation details, not browser-callable RPCs.
revoke all on function public.ft_bookkeeping_guard_journal() from public, anon, authenticated;
revoke all on function public.ft_bookkeeping_guard_journal_line() from public, anon, authenticated;
revoke all on function public.ft_bookkeeping_capture_audit() from public, anon, authenticated;
revoke all on function public.ft_bookkeeping_reject_audit_mutation() from public, anon, authenticated;

commit;
