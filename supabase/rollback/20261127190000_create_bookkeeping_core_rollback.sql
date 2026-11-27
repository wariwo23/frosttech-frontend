-- FrostTech Bookkeeping Core — guarded rollback candidate
-- This rollback intentionally refuses to drop any table containing data.
-- If any bookkeeping rows exist, stop and prepare a data-preserving forward repair instead.

begin;

do $$
declare
  v_counts text;
begin
  select string_agg(format('%I=%s', t.table_name, t.row_count), ', ')
    into v_counts
  from (
    select 'ft_bookkeeping_accounts' table_name, count(*) row_count from public.ft_bookkeeping_accounts
    union all select 'ft_bookkeeping_audit_log', count(*) from public.ft_bookkeeping_audit_log
    union all select 'ft_bookkeeping_bank_accounts', count(*) from public.ft_bookkeeping_bank_accounts
    union all select 'ft_bookkeeping_bank_transactions', count(*) from public.ft_bookkeeping_bank_transactions
    union all select 'ft_bookkeeping_documents', count(*) from public.ft_bookkeeping_documents
    union all select 'ft_bookkeeping_expenses', count(*) from public.ft_bookkeeping_expenses
    union all select 'ft_bookkeeping_fixed_assets', count(*) from public.ft_bookkeeping_fixed_assets
    union all select 'ft_bookkeeping_journal_lines', count(*) from public.ft_bookkeeping_journal_lines
    union all select 'ft_bookkeeping_journals', count(*) from public.ft_bookkeeping_journals
    union all select 'ft_bookkeeping_periods', count(*) from public.ft_bookkeeping_periods
    union all select 'ft_bookkeeping_reconciliations', count(*) from public.ft_bookkeeping_reconciliations
    union all select 'ft_bookkeeping_shareholder_loans', count(*) from public.ft_bookkeeping_shareholder_loans
  ) t
  where t.row_count > 0;

  if v_counts is not null then
    raise exception 'Rollback refused: bookkeeping data exists (%). Use a data-preserving forward repair; do not drop financial records.', v_counts;
  end if;
end $$;

drop trigger if exists ft_bookkeeping_accounts_audit on public.ft_bookkeeping_accounts;
drop trigger if exists ft_bookkeeping_bank_accounts_audit on public.ft_bookkeeping_bank_accounts;
drop trigger if exists ft_bookkeeping_bank_transactions_audit on public.ft_bookkeeping_bank_transactions;
drop trigger if exists ft_bookkeeping_documents_audit on public.ft_bookkeeping_documents;
drop trigger if exists ft_bookkeeping_expenses_audit on public.ft_bookkeeping_expenses;
drop trigger if exists ft_bookkeeping_fixed_assets_audit on public.ft_bookkeeping_fixed_assets;
drop trigger if exists ft_bookkeeping_periods_audit on public.ft_bookkeeping_periods;
drop trigger if exists ft_bookkeeping_reconciliations_audit on public.ft_bookkeeping_reconciliations;
drop trigger if exists ft_bookkeeping_shareholder_loans_audit on public.ft_bookkeeping_shareholder_loans;
drop trigger if exists ft_bookkeeping_audit_immutable on public.ft_bookkeeping_audit_log;
drop trigger if exists ft_bookkeeping_journal_lines_audit on public.ft_bookkeeping_journal_lines;
drop trigger if exists ft_bookkeeping_journals_audit on public.ft_bookkeeping_journals;
drop trigger if exists ft_bookkeeping_journal_line_guard on public.ft_bookkeeping_journal_lines;
drop trigger if exists ft_bookkeeping_journal_guard on public.ft_bookkeeping_journals;
drop function if exists public.ft_bookkeeping_guard_journal_line();
drop function if exists public.ft_bookkeeping_reject_audit_mutation();
drop function if exists public.ft_bookkeeping_capture_audit();
drop function if exists public.ft_bookkeeping_guard_journal();

drop table public.ft_bookkeeping_shareholder_loans;
drop table public.ft_bookkeeping_reconciliations;
drop table public.ft_bookkeeping_fixed_assets;
drop table public.ft_bookkeeping_expenses;
drop table public.ft_bookkeeping_documents;
drop table public.ft_bookkeeping_bank_transactions;
drop table public.ft_bookkeeping_journal_lines;
drop table public.ft_bookkeeping_bank_accounts;
drop table public.ft_bookkeeping_journals;
drop table public.ft_bookkeeping_periods;
drop table public.ft_bookkeeping_audit_log;
drop table public.ft_bookkeeping_accounts;

commit;
