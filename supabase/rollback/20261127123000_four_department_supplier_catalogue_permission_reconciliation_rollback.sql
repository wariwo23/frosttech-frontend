-- Rollback for four_department_supplier_catalogue_permission_reconciliation.
-- Removes only the newly added canonical-role permission; legacy role mappings remain untouched.
begin;
delete from public.admin_role_permissions
where role='supplier_catalogue_admin'
  and permission='supplier_quotes.manage';
commit;
