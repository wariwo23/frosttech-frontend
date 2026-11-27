-- Rollback for quotation and direct-quotation authorization hardening.
-- Restores the prior policy and anonymous table grants. This reintroduces the
-- broader legacy authorization behavior and should be used only for recovery.

begin;

drop policy if exists department_operations_quotations_read on public.admin_quotations;
drop policy if exists department_operations_quotations_insert_draft on public.admin_quotations;
drop policy if exists department_operations_quotations_update_draft on public.admin_quotations;

drop policy if exists department_operations_quotation_items_read on public.admin_quotation_items;
drop policy if exists department_finance_quotation_items_read on public.admin_quotation_items;
create policy admin_quotation_items_admin_manage
on public.admin_quotation_items
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists department_operations_quotation_pricing_manage on public.admin_quotation_pricing_snapshots;
create policy "Admins manage quotation pricing snapshots"
on public.admin_quotation_pricing_snapshots
for all to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

grant all on table public.admin_quotations to anon;
grant all on table public.admin_quotation_items to anon;
grant select, update, delete, references, trigger on table public.quote_requests to anon;
grant insert on table public.quote_requests to anon;

commit;
