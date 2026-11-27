-- Legacy administrator-policy retirement and department-scoped RLS.
-- Preserves customer ownership, advertiser self-service and public active package reads.
-- No business records or payment states are changed.

begin;

do $preflight$
begin
  if not exists(select 1 from public.admin_role_permissions where role='operations_admin' and permission='customer_requests.manage') then
    raise exception 'Operations permission customer_requests.manage is missing';
  end if;
  if not exists(select 1 from public.admin_role_permissions where role='finance_admin' and permission='payments.read') then
    raise exception 'Finance permission payments.read is missing';
  end if;
  if not exists(select 1 from public.admin_role_permissions where role='advertisers_admin' and permission='advertisements.review') then
    raise exception 'Advertisers permission advertisements.review is missing';
  end if;
  if not exists(select 1 from public.admin_role_permissions where role='advertisers_admin' and permission='advertisers.manage') then
    raise exception 'Advertisers permission advertisers.manage is missing';
  end if;
  if not exists(select 1 from public.admin_role_permissions where role='advertisers_admin' and permission='notifications.manage') then
    raise exception 'Advertisers permission notifications.manage is missing';
  end if;
end;
$preflight$;

-- Global system controls remain Super-Administrator-only.
drop policy if exists admin_controls_admin on public.admin_controls;
drop policy if exists super_admin_controls_manage on public.admin_controls;
create policy super_admin_controls_manage
on public.admin_controls for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

-- Advertising enquiries: Advertisers & Communications may review and manage.
drop policy if exists "Advertising admins manage enquiries" on public.advertisement_enquiries;
drop policy if exists department_advertisers_manage_enquiries on public.advertisement_enquiries;
create policy department_advertisers_manage_enquiries
on public.advertisement_enquiries for all to authenticated
using (public.admin_has_permission('advertisements.review'))
with check (public.admin_has_permission('advertisements.review'));

-- Package pricing/configuration remains under Super Administrator control.
drop policy if exists "Advertising admins manage packages" on public.advertising_packages;
drop policy if exists super_admin_advertising_packages_manage on public.advertising_packages;
create policy super_admin_advertising_packages_manage
on public.advertising_packages for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());
-- Existing public active-package SELECT policy is deliberately preserved.

-- Finance can read advertising payment records; verification and mutation remain
-- in protected payment/webhook workflows. Super Administrator retains full access.
drop policy if exists "Advertising admins manage payments" on public.advertising_payments;
drop policy if exists super_admin_advertising_payments_manage on public.advertising_payments;
create policy super_admin_advertising_payments_manage
on public.advertising_payments for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());
drop policy if exists department_finance_advertising_payments_read on public.advertising_payments;
create policy department_finance_advertising_payments_read
on public.advertising_payments for select to authenticated
using (public.admin_has_permission('payments.read'));
-- Existing advertiser-own-payment SELECT policy is preserved.

-- Advertisers admin may inspect accepted terms; only Super Administrator
-- can perform unrestricted administrative mutations.
drop policy if exists "Advertising admins manage terms" on public.advertising_terms_acceptance;
drop policy if exists super_admin_advertising_terms_manage on public.advertising_terms_acceptance;
create policy super_admin_advertising_terms_manage
on public.advertising_terms_acceptance for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());
drop policy if exists department_advertisers_terms_read on public.advertising_terms_acceptance;
create policy department_advertisers_terms_read
on public.advertising_terms_acceptance for select to authenticated
using (public.admin_has_permission('advertisers.manage'));
-- Existing advertiser-own-terms SELECT policy is preserved.

-- Operations can manage customer requests; customers retain access to their own
-- linked requests. Super Administrator passes the department permission helper.
drop policy if exists requests_customer_access on public.customer_requests;
drop policy if exists department_operations_customer_requests_manage on public.customer_requests;
create policy department_operations_customer_requests_manage
on public.customer_requests for all to authenticated
using (
  public.admin_has_permission('customer_requests.manage')
  or customer_id in (select c.id from public.customers c where c.user_id=auth.uid())
)
with check (
  public.admin_has_permission('customer_requests.manage')
  or customer_id in (select c.id from public.customers c where c.user_id=auth.uid())
);

-- Customer records: customers retain full self-service on their own row;
-- Operations gets read-only oversight; Super Administrator retains full authority.
drop policy if exists customers_self_access on public.customers;
drop policy if exists customers_own_record_manage on public.customers;
create policy customers_own_record_manage
on public.customers for all to authenticated
using (user_id=auth.uid())
with check (user_id=auth.uid());
drop policy if exists department_operations_customers_read on public.customers;
create policy department_operations_customers_read
on public.customers for select to authenticated
using (public.admin_has_permission('customer_requests.manage'));
drop policy if exists super_admin_customers_manage on public.customers;
create policy super_admin_customers_manage
on public.customers for all to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

-- Notification ownership remains intact; Communications receives the mapped
-- notification-management authority. Super Administrator passes all permissions.
drop policy if exists notifications_admin_manage on public.notifications;
drop policy if exists notifications_own on public.notifications;
drop policy if exists department_notifications_manage on public.notifications;
create policy department_notifications_manage
on public.notifications for all to authenticated
using (public.admin_has_permission('notifications.manage'))
with check (public.admin_has_permission('notifications.manage'));
create policy notifications_owner_read
on public.notifications for select to authenticated
using (user_id=auth.uid() or public.admin_has_permission('notifications.manage'));

-- Approved quotation snapshots are customer-visible to the order owner and
-- remain Super-Administrator-only for cross-customer administrative reads.
drop policy if exists order_quotation_snapshots_customer_read on public.order_quotation_snapshots;
drop policy if exists order_quotation_snapshots_customer_or_super_admin_read on public.order_quotation_snapshots;
create policy order_quotation_snapshots_customer_or_super_admin_read
on public.order_quotation_snapshots for select to authenticated
using (
  exists (
    select 1
    from public.orders o
    join public.customers c on c.id=o.customer_id
    where o.id=order_quotation_snapshots.order_id
      and (c.user_id=auth.uid() or public.is_super_admin())
  )
);

-- All RLS policies and audited database functions have now been checked for
-- legacy is_admin() references. Remove direct RPC execution to prevent public
-- exposure of the old profile-role boolean helper.
revoke all on function public.is_admin() from public, anon, authenticated;

commit;
