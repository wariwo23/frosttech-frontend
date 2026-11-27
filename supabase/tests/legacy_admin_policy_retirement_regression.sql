-- Legacy is_admin retirement regression checks. Run only in isolated test project.

do $checks$
declare v_count integer; v_def text;
begin
  if has_function_privilege('anon','public.is_admin()','EXECUTE')
     or has_function_privilege('authenticated','public.is_admin()','EXECUTE') then
    raise exception 'Legacy is_admin RPC remains executable';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public'
      and (coalesce(qual,'') ilike '%is_admin%' or coalesce(with_check,'') ilike '%is_admin%')
  ) then
    raise exception 'One or more RLS policies still reference legacy is_admin()';
  end if;

  if not exists(select 1 from pg_policies where schemaname='public' and tablename='admin_controls' and policyname='super_admin_controls_manage' and cmd='ALL') then raise exception 'Super Admin controls policy missing'; end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='customer_requests' and policyname='department_operations_customer_requests_manage' and cmd='ALL') then raise exception 'Operations customer request policy missing'; end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='customers' and policyname='department_operations_customers_read' and cmd='SELECT') then raise exception 'Operations customer read-only policy missing'; end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='advertising_payments' and policyname='department_finance_advertising_payments_read' and cmd='SELECT') then raise exception 'Finance advertising payment read policy missing'; end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='advertisement_enquiries' and policyname='department_advertisers_manage_enquiries' and cmd='ALL') then raise exception 'Advertisers enquiries policy missing'; end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='notifications' and policyname='department_notifications_manage' and cmd='ALL') then raise exception 'Communications notification policy missing'; end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='advertising_packages' and policyname='Public can read active advertising packages') then
    if not exists(select 1 from pg_policies where schemaname='public' and tablename='advertising_packages' and policyname='Test public reads active advertising packages') then
      raise exception 'Public active advertising package read policy was lost';
    end if;
  end if;

  select pg_get_functiondef('public.admin_has_permission(text)'::regprocedure) into v_def;
  if position('a.role = ''super_admin''' in v_def)=0 then raise exception 'Super Admin permission bypass was altered'; end if;
end;
$checks$;

-- Test the four-department permission helper using the isolated Operations account.
begin;
set local request.jwt.claim.sub='3f783825-9ee0-4e7f-b792-eddc29a8b772';
set local role authenticated;
do $operations$
begin
 if not public.admin_has_permission('customer_requests.manage') then raise exception 'Operations lost customer request authority'; end if;
 if public.is_super_admin() then raise exception 'Operations account incorrectly resolves as Super Admin'; end if;
 if public.admin_has_permission('payments.read') then raise exception 'Operations unexpectedly has Finance payment access'; end if;
 if public.admin_has_permission('advertisements.review') then raise exception 'Operations unexpectedly has Advertiser review access'; end if;
end;
$operations$;
rollback;

-- Super Administrator retains unrestricted authority through the protected helper.
begin;
set local request.jwt.claim.sub='7fb39f06-ce75-437c-8676-7a6141cf9664';
set local role authenticated;
do $super_admin$
begin
 if not public.is_super_admin() then raise exception 'Super Administrator role was not recognized'; end if;
 if not public.admin_has_permission('customer_requests.manage') then raise exception 'Super Administrator lost Operations permission'; end if;
 if not public.admin_has_permission('payments.read') then raise exception 'Super Administrator lost Finance permission'; end if;
 if not public.admin_has_permission('advertisements.review') then raise exception 'Super Administrator lost Advertiser permission'; end if;
end;
$super_admin$;
rollback;

select 'PASS' result,'Legacy is_admin policy retirement and department permission regression checks passed.' detail;
