-- Employee onboarding / four-department regression checks.
-- Read-only assertions: no employee, auth, or admin-account rows are created or changed.

do $test$
declare
  v_definition text;
  v_super_count integer;
  v_department_count integer;
begin
  v_definition := pg_get_functiondef(
    'public.admin_create_frosttech_employee(text,text,text,text)'::regprocedure
  );

  if position('supplier_catalogue' in v_definition)=0 then
    raise exception 'FAIL: employee creation does not accept supplier_catalogue';
  end if;
  if position('advertisers_communications' in v_definition)=0 then
    raise exception 'FAIL: employee creation does not accept advertisers_communications';
  end if;
  if position('supplier_management' in v_definition)=0
     or position('catalogue' in v_definition)=0 then
    raise exception 'FAIL: legacy department values were not preserved';
  end if;

  if not exists (
    select 1 from public.admin_role_permissions
    where role='supplier_catalogue_admin'
      and permission='supplier_quotes.manage'
  ) then
    raise exception 'FAIL: Supplier & Catalogue role lacks supplier quote management';
  end if;

  select count(*) into v_super_count
  from public.admin_accounts
  where role='super_admin' and is_active=true;

  if v_super_count <> 1 then
    raise exception 'FAIL: expected exactly one active Super Administrator, found %',v_super_count;
  end if;

  select count(*) into v_department_count
  from public.admin_accounts
  where is_active=true and role in (
    'operations_admin','supplier_catalogue_admin','finance_admin','advertisers_admin'
  );

  if v_department_count <> 0 then
    raise exception 'Review required: expected zero departmental appointments in current baseline, found %',v_department_count;
  end if;
end
$test$;
