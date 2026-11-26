-- Applied to production Supabase project nftxptjpgidcsgtaltjn on 2026-11-26.
-- Grants Finance Administrator the test-verified bookkeeping, tax operations,
-- and supplier-settlement preparation/read permissions.
-- Does not grant tax-rule administration or final settlement approval.

begin;
insert into public.admin_role_permissions(role,permission)
select 'finance_admin',p.permission
from (values
 ('bookkeeping.documents.manage'),
 ('bookkeeping.prepare'),
 ('bookkeeping.read'),
 ('bookkeeping.reports.read'),
 ('supplier_settlements.audit.read'),
 ('supplier_settlements.prepare'),
 ('supplier_settlements.read'),
 ('tax.assessments.manage'),
 ('tax.assessments.read'),
 ('tax.certificates.manage'),
 ('tax.remittances.manage'),
 ('tax.rules.read'),
 ('tax.supplier_profiles.manage'),
 ('tax.supplier_profiles.read')
) as p(permission)
where not exists (
 select 1 from public.admin_role_permissions x
 where x.role='finance_admin' and x.permission=p.permission
);
commit;
