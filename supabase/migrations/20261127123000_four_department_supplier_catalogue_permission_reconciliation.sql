-- Four-department role reconciliation.
-- Consolidates supplier quotation authority into the canonical Supplier & Catalogue role.
-- Legacy supplier_admin and catalogue_admin permission rows remain untouched for backward compatibility.

begin;
insert into public.admin_role_permissions(role,permission)
values ('supplier_catalogue_admin','supplier_quotes.manage')
on conflict (role,permission) do nothing;
commit;
