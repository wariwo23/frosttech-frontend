-- FrostTech advertising authorization regression checks.
-- Safe to run in production: no persistent rows or permissions are changed.

begin;

-- Super Administrator must retain every advertising review capability.
select set_config(
  'request.jwt.claim.sub',
  (select user_id::text from public.admin_accounts
   where role='super_admin' and is_active=true limit 1),
  true
);

do $test$
declare
  v_count integer;
begin
  if not public.admin_has_permission('advertisements.review') then
    raise exception 'FAIL: Super Administrator lacks advertisements.review';
  end if;
  if not public.admin_has_permission('advertiser_documents.review') then
    raise exception 'FAIL: Super Administrator lacks advertiser_documents.review';
  end if;
  if not public.admin_has_permission('advertisers.manage') then
    raise exception 'FAIL: Super Administrator lacks advertisers.manage';
  end if;

  select count(*) into v_count
  from pg_policies
  where schemaname='public'
    and tablename in ('advertisement_submissions','advertiser_documents','advertisers','advertising_order_items','advertising_orders')
    and policyname in (
      'Advertising reviewers read submissions',
      'Advertiser document reviewers read documents',
      'Advertiser reviewers read advertiser records',
      'Advertising reviewers read order items',
      'Advertising reviewers read orders'
    )
    and cmd='SELECT';
  if v_count <> 5 then
    raise exception 'FAIL: Expected five permission-scoped advertising SELECT policies, found %',v_count;
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename in ('advertisement_submissions','advertiser_documents','advertisers','advertising_order_items','advertising_orders')
      and policyname in (
        'Advertising admins manage submissions',
        'Advertising admins manage documents',
        'Advertising admins manage advertisers',
        'Advertising admins manage order items',
        'Advertising admins manage orders'
      )
  ) then
    raise exception 'FAIL: A legacy broad advertising admin policy remains';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname='Authorised advertiser reviewers read private documents'
      and cmd='SELECT'
  ) then
    raise exception 'FAIL: Private advertiser document reviewer read policy is missing';
  end if;

  if position('admin_has_permission' in pg_get_functiondef('public.admin_review_advertiser(uuid,text,text)'::regprocedure))=0 then
    raise exception 'FAIL: Advertiser review RPC lacks department permission check';
  end if;
  if position('admin_has_permission' in pg_get_functiondef('public.admin_review_advertiser_document(uuid,text,text)'::regprocedure))=0 then
    raise exception 'FAIL: Advertiser document review RPC lacks department permission check';
  end if;
end
$test$;

-- Anonymous identity must not receive departmental permissions.
select set_config('request.jwt.claim.sub','',true);
do $anonymous_test$
begin
  if public.admin_has_permission('advertisements.review') then
    raise exception 'FAIL: Anonymous identity has advertisements.review';
  end if;
  if public.admin_has_permission('advertiser_documents.review') then
    raise exception 'FAIL: Anonymous identity has advertiser_documents.review';
  end if;
  if public.admin_has_permission('advertisers.manage') then
    raise exception 'FAIL: Anonymous identity has advertisers.manage';
  end if;
end
$anonymous_test$;

rollback;
