-- Regression assertions for supplier & catalogue authorization hardening.
-- Run after migration 20261127230000.

do $test$
declare
  v_def text;
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='suppliers'
      and policyname='suppliers_read_own_or_authorized'
      and cmd='SELECT'
  ) then
    raise exception 'Permission-gated supplier read policy is missing';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='suppliers'
      and policyname in (
        'suppliers_admin_delete',
        'suppliers_admin_insert',
        'suppliers_admin_update',
        'suppliers_read_own_or_admin'
      )
  ) then
    raise exception 'Legacy broad supplier policies remain';
  end if;

  select pg_get_functiondef(
    'public.admin_review_supplier(uuid,text,text)'::regprocedure
  ) into v_def;

  if position('admin_has_permission(''supplier_verification.manage'')' in v_def)=0 then
    raise exception 'Supplier review permission check is missing';
  end if;
  if position('FOR UPDATE' in upper(v_def))=0 then
    raise exception 'Supplier review row lock is missing';
  end if;
  if position('is_active = (new_status = ''approved'')' in v_def)=0 then
    raise exception 'Supplier activation state is not restricted to approved status';
  end if;
  if position('is_admin()' in lower(v_def))>0 then
    raise exception 'Legacy is_admin check remains in supplier review function';
  end if;

  if not exists (
    select 1 from public.admin_role_permissions
    where role='supplier_catalogue_admin'
      and permission='supplier_verification.manage'
  ) then
    raise exception 'Supplier Catalogue role is missing supplier verification permission';
  end if;

  if not exists (
    select 1 from public.admin_role_permissions
    where role='supplier_catalogue_admin'
      and permission='supplier_applications.read'
  ) then
    raise exception 'Supplier Catalogue role is missing supplier application read permission';
  end if;

  if not exists (
    select 1 from public.admin_role_permissions
    where role='finance_admin'
      and permission='supplier_settlements.read'
  ) then
    raise exception 'Finance supplier settlement read permission is missing';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.admin_review_supplier(uuid,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated RPC execution grant was not preserved';
  end if;
end;
$test$;

select
  'PASS' as result,
  'Supplier reads are permission-gated; direct administrator DML policies removed; review RPC is permission-checked and row-locked.' as detail;
