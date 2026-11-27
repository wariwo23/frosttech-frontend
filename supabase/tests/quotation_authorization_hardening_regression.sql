-- Quotation and direct-quotation authorization regression checks.
-- Run after the test-only alignment fixture and migration.

do $assertions$
declare
  v_def text;
begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='admin_quotations' and policyname='department_operations_quotations_read' and cmd='SELECT') then
    raise exception 'Operations quotation read policy missing';
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='admin_quotations' and policyname='department_operations_quotations_insert_draft' and cmd='INSERT') then
    raise exception 'Operations draft insert policy missing';
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='admin_quotations' and policyname='department_operations_quotations_update_draft' and cmd='UPDATE') then
    raise exception 'Operations draft update policy missing';
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='admin_quotation_items' and policyname='department_finance_quotation_items_read' and cmd='SELECT') then
    raise exception 'Finance quotation-item read policy missing';
  end if;
  if exists(select 1 from pg_policies where schemaname='public' and tablename='admin_quotation_items' and policyname='admin_quotation_items_admin_manage') then
    raise exception 'Legacy is_admin quotation-item policy remains';
  end if;
  if exists(select 1 from pg_policies where schemaname='public' and tablename='admin_quotation_pricing_snapshots' and policyname='Admins manage quotation pricing snapshots') then
    raise exception 'Legacy is_admin pricing-snapshot policy remains';
  end if;

  if has_table_privilege('anon','public.admin_quotations','SELECT')
     or has_table_privilege('anon','public.admin_quotation_items','SELECT')
     or has_table_privilege('anon','public.admin_quotation_items','INSERT')
     or has_table_privilege('anon','public.admin_quotation_items','UPDATE')
     or has_table_privilege('anon','public.admin_quotation_items','DELETE') then
    raise exception 'Anonymous quotation table privileges remain';
  end if;
  if has_table_privilege('anon','public.quote_requests','SELECT')
     or has_table_privilege('anon','public.quote_requests','UPDATE')
     or has_table_privilege('anon','public.quote_requests','DELETE')
     or not has_table_privilege('anon','public.quote_requests','INSERT') then
    raise exception 'Guest quote-request privileges are not INSERT-only';
  end if;

  select pg_get_functiondef('public.admin_create_direct_quotation_revision_v2(uuid)'::regprocedure) into v_def;
  if position('admin_has_permission(''quotations.manage'')' in v_def)=0 then raise exception 'Quotation revision RPC permission check missing'; end if;
  select pg_get_functiondef('public.admin_replace_direct_quotation_items_v2(uuid,jsonb)'::regprocedure) into v_def;
  if position('admin_has_permission(''quotations.manage'')' in v_def)=0 then raise exception 'Quotation item replacement RPC permission check missing'; end if;
  select pg_get_functiondef('public.admin_submit_direct_quotation(uuid)'::regprocedure) into v_def;
  if position('admin_has_permission(''quotations.manage'')' in v_def)=0 then raise exception 'Quotation submission RPC permission check missing'; end if;
  select pg_get_functiondef('public.frosttech_get_request_alternative_review_v1(uuid)'::regprocedure) into v_def;
  if position('quotations.read_financial' in v_def)=0 then raise exception 'Alternative review financial visibility check missing'; end if;
end;
$assertions$;

-- Operations role: read quotations, line items and private pricing snapshots.
begin;
set local request.jwt.claim.sub='3f783825-9ee0-4e7f-b792-eddc29a8b772';
set local role authenticated;
do $operations$
declare v_count integer;
begin
  if not public.admin_has_permission('quotations.manage') then raise exception 'Operations quotation permission missing'; end if;
  select count(*) into v_count from public.admin_quotations;
  select count(*) into v_count from public.admin_quotation_items;
  select count(*) into v_count from public.admin_quotation_pricing_snapshots;
end;
$operations$;
rollback;

-- Finance role: read quotation totals and line items, but never private pricing inputs.
begin;
set local request.jwt.claim.sub='55ef7cb8-6c06-481a-be21-22f4f98c0d6a';
set local role authenticated;
do $finance$
declare v_count integer;
begin
  if not public.admin_has_permission('quotations.read_financial') then raise exception 'Finance financial-read permission missing'; end if;
  if public.admin_has_permission('quotations.manage') then raise exception 'Finance unexpectedly has quotation-management permission'; end if;
  select count(*) into v_count from public.admin_quotations;
  select count(*) into v_count from public.admin_quotation_items;
  select count(*) into v_count from public.admin_quotation_pricing_snapshots;
  if v_count<>0 then raise exception 'Finance can read private pricing snapshots'; end if;
end;
$finance$;
rollback;

-- Super Administrator: retains full quotation and private pricing access.
begin;
set local request.jwt.claim.sub='7fb39f06-ce75-437c-8676-7a6141cf9664';
set local role authenticated;
do $super$
declare v_count integer;
begin
  if not public.admin_has_permission('quotations.manage') or not public.admin_has_permission('quotations.read_financial') then
    raise exception 'Super Administrator quotation permissions were reduced';
  end if;
  select count(*) into v_count from public.admin_quotations;
  select count(*) into v_count from public.admin_quotation_items;
  select count(*) into v_count from public.admin_quotation_pricing_snapshots;
end;
$super$;
rollback;

select 'PASS' as result,
'Operations quotation management, Finance read-only line items, private pricing isolation, Super Administrator access, RPC permission checks and guest INSERT-only privileges passed.' as detail;
