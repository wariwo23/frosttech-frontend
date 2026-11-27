begin;

-- Controlled register reconciliation: register rows reference existing posted
-- journals; this migration never creates, edits, or reposts journal entries.

create unique index if not exists ft_bookkeeping_expenses_journal_unique
  on public.ft_bookkeeping_expenses (journal_id)
  where journal_id is not null;

create unique index if not exists ft_bookkeeping_shareholder_loans_journal_unique
  on public.ft_bookkeeping_shareholder_loans (journal_id)
  where journal_id is not null;

drop policy if exists ft_bookkeeping_expenses_insert on public.ft_bookkeeping_expenses;
create policy ft_bookkeeping_expenses_insert
  on public.ft_bookkeeping_expenses
  for insert to authenticated
  with check (public.is_super_admin());

drop policy if exists ft_bookkeeping_loans_write on public.ft_bookkeeping_shareholder_loans;
create policy ft_bookkeeping_loans_write
  on public.ft_bookkeeping_shareholder_loans
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

grant insert on table
  public.ft_bookkeeping_expenses,
  public.ft_bookkeeping_shareholder_loans
to authenticated;

commit;
