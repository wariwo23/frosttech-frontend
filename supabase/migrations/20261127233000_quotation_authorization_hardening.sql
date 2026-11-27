-- Quotation and direct-quotation authorization hardening
-- Aligns direct draft workflow with the four-department permission model.
-- Does not alter quotation records, amounts, fee calculations, or customer decisions.

begin;

do $preflight$
begin
  if to_regclass('public.admin_quotations') is null
     or to_regclass('public.admin_quotation_items') is null
     or to_regclass('public.admin_quotation_pricing_snapshots') is null
     or to_regclass('public.quote_requests') is null then
    raise exception 'Quotation authorization migration preflight failed: required tables are missing';
  end if;

  if not exists (
    select 1 from public.admin_role_permissions
    where role='operations_admin' and permission='quotations.manage'
  ) then
    raise exception 'Operations role is missing quotations.manage; reconcile role permissions before applying this migration';
  end if;

  if not exists (
    select 1 from public.admin_role_permissions
    where role='finance_admin' and permission='quotations.read_financial'
  ) then
    raise exception 'Finance role is missing quotations.read_financial; reconcile role permissions before applying this migration';
  end if;
end;
$preflight$;

-- Operations may read quotation history and create/update drafts only.
-- The existing Super Administrator ALL policy remains in place.
drop policy if exists department_operations_quotations_read on public.admin_quotations;
create policy department_operations_quotations_read
on public.admin_quotations
for select to authenticated
using (public.admin_has_permission('quotations.manage'));

drop policy if exists department_operations_quotations_insert_draft on public.admin_quotations;
create policy department_operations_quotations_insert_draft
on public.admin_quotations
for insert to authenticated
with check (
  public.admin_has_permission('quotations.manage')
  and status='draft'
);

drop policy if exists department_operations_quotations_update_draft on public.admin_quotations;
create policy department_operations_quotations_update_draft
on public.admin_quotations
for update to authenticated
using (
  public.admin_has_permission('quotations.manage')
  and status='draft'
)
with check (
  public.admin_has_permission('quotations.manage')
  and status='draft'
);

-- Finance receives read-only access to quotation items, not private pricing inputs.
drop policy if exists admin_quotation_items_admin_manage on public.admin_quotation_items;
drop policy if exists department_operations_quotation_items_read on public.admin_quotation_items;
create policy department_operations_quotation_items_read
on public.admin_quotation_items
for select to authenticated
using (public.admin_has_permission('quotations.manage'));

drop policy if exists department_finance_quotation_items_read on public.admin_quotation_items;
create policy department_finance_quotation_items_read
on public.admin_quotation_items
for select to authenticated
using (public.admin_has_permission('quotations.read_financial'));

-- Only Operations (and Super Administrator through the permission helper)
-- can read/write the private pricing inputs used to prepare quotation drafts.
drop policy if exists "Admins manage quotation pricing snapshots" on public.admin_quotation_pricing_snapshots;
drop policy if exists department_operations_quotation_pricing_manage on public.admin_quotation_pricing_snapshots;
create policy department_operations_quotation_pricing_manage
on public.admin_quotation_pricing_snapshots
for all to authenticated
using (public.admin_has_permission('quotations.manage'))
with check (public.admin_has_permission('quotations.manage'));

-- Anonymous users submit guest requests through INSERT only. They must not
-- have direct read/update/delete access to customer or quotation records.
revoke all on table public.admin_quotations from anon;
revoke all on table public.admin_quotation_items from anon;
revoke select, update, delete, references, trigger on table public.quote_requests from anon;
grant insert on table public.quote_requests to anon;

comment on policy department_operations_quotations_read on public.admin_quotations
is 'Operations quotation managers can read quotation records; Finance uses its separate read-only permission.';
comment on policy department_operations_quotations_insert_draft on public.admin_quotations
is 'Operations may create draft quotations only; submission remains a permission-checked RPC.';
comment on policy department_operations_quotations_update_draft on public.admin_quotations
is 'Operations may update drafts only; submitted and accepted records are immutable through direct table access.';
comment on policy department_finance_quotation_items_read on public.admin_quotation_items
is 'Finance may read quotation line items but cannot change them or access private pricing snapshots.';

commit;
