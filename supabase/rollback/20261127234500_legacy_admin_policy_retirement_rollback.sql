-- Emergency rollback: restores the legacy is_admin()-based policies and RPC grants.
-- WARNING: this restores broad profile-role authorization and is not a preferred steady state.

begin;

drop policy if exists super_admin_controls_manage on public.admin_controls;
create policy admin_controls_admin on public.admin_controls for all to public
using (public.is_admin()) with check (public.is_admin());

drop policy if exists department_advertisers_manage_enquiries on public.advertisement_enquiries;
create policy "Advertising admins manage enquiries" on public.advertisement_enquiries
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists super_admin_advertising_packages_manage on public.advertising_packages;
create policy "Advertising admins manage packages" on public.advertising_packages
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists super_admin_advertising_payments_manage on public.advertising_payments;
drop policy if exists department_finance_advertising_payments_read on public.advertising_payments;
create policy "Advertising admins manage payments" on public.advertising_payments
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists super_admin_advertising_terms_manage on public.advertising_terms_acceptance;
drop policy if exists department_advertisers_terms_read on public.advertising_terms_acceptance;
create policy "Advertising admins manage terms" on public.advertising_terms_acceptance
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists department_operations_customer_requests_manage on public.customer_requests;
create policy requests_customer_access on public.customer_requests for all to public
using (
  public.is_admin()
  or customer_id in (select c.id from public.customers c where c.user_id=auth.uid())
)
with check (
  public.is_admin()
  or customer_id in (select c.id from public.customers c where c.user_id=auth.uid())
);

drop policy if exists customers_own_record_manage on public.customers;
drop policy if exists department_operations_customers_read on public.customers;
drop policy if exists super_admin_customers_manage on public.customers;
create policy customers_self_access on public.customers for all to public
using (user_id=auth.uid() or public.is_admin())
with check (user_id=auth.uid() or public.is_admin());

drop policy if exists department_notifications_manage on public.notifications;
drop policy if exists notifications_owner_read on public.notifications;
create policy notifications_admin_manage on public.notifications for all to public
using (public.is_admin()) with check (public.is_admin());
create policy notifications_own on public.notifications for select to public
using (user_id=auth.uid() or public.is_admin());

drop policy if exists order_quotation_snapshots_customer_or_super_admin_read on public.order_quotation_snapshots;
create policy order_quotation_snapshots_customer_read on public.order_quotation_snapshots
for select to authenticated
using (
  exists (
    select 1 from public.orders o
    join public.customers c on c.id=o.customer_id
    where o.id=order_quotation_snapshots.order_id
      and (c.user_id=auth.uid() or public.is_admin())
  )
);

grant execute on function public.is_admin() to public, anon, authenticated;

commit;
