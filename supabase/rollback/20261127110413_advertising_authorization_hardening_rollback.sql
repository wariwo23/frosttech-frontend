-- Rollback for 20261128010000_advertising_authorization_hardening.sql.
-- Restores prior legacy policies and Super Administrator-only advertiser review RPC gates.

begin;

drop policy if exists "Advertising reviewers read submissions" on public.advertisement_submissions;
drop policy if exists "Advertiser document reviewers read documents" on public.advertiser_documents;
drop policy if exists "Advertiser reviewers read advertiser records" on public.advertisers;
drop policy if exists "Advertising reviewers read order items" on public.advertising_order_items;
drop policy if exists "Advertising reviewers read orders" on public.advertising_orders;

create policy "Advertising admins manage submissions"
on public.advertisement_submissions for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "Advertising admins manage documents"
on public.advertiser_documents for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "Advertising admins manage advertisers"
on public.advertisers for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "Advertising admins manage order items"
on public.advertising_order_items for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "Advertising admins manage orders"
on public.advertising_orders for all to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Authorised advertiser reviewers read private documents" on storage.objects;
create policy "FrostTech admins manage advertiser documents"
on storage.objects for all to authenticated
using (bucket_id = 'advertiser-documents' and public.is_admin())
with check (bucket_id = 'advertiser-documents' and public.is_admin());

do $rollback$
declare
  v_oid oid;
  v_definition text;
  v_old text;
  v_new text;
begin
  v_oid := to_regprocedure('public.admin_review_advertiser(uuid,text,text)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_review_advertiser(uuid,text,text)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'IF auth.uid() IS NULL OR NOT public.admin_has_permission(''advertisers.manage'') THEN';
  v_new := 'IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_review_advertiser(uuid,text,text)';
  end if;
  execute v_definition;

  v_oid := to_regprocedure('public.admin_review_advertiser_document(uuid,text,text)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_review_advertiser_document(uuid,text,text)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'IF auth.uid() IS NULL OR NOT public.admin_has_permission(''advertiser_documents.review'') THEN';
  v_new := 'IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_review_advertiser_document(uuid,text,text)';
  end if;
  execute v_definition;
end
$rollback$;

commit;
