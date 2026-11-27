-- Advertising workflow authorization hardening.
-- Preserve advertiser self-service policies. Admin browser access is read-only;
-- all privileged campaign writes remain in the JWT-verified Edge Function/service role
-- and advertiser review SECURITY DEFINER RPCs.

begin;

-- Replace legacy broad administrator ALL policies with narrowly scoped SELECT policies.
drop policy if exists "Advertising admins manage submissions" on public.advertisement_submissions;
drop policy if exists "Advertising admins manage documents" on public.advertiser_documents;
drop policy if exists "Advertising admins manage advertisers" on public.advertisers;
drop policy if exists "Advertising admins manage order items" on public.advertising_order_items;
drop policy if exists "Advertising admins manage orders" on public.advertising_orders;

create policy "Advertising reviewers read submissions"
on public.advertisement_submissions
for select to authenticated
using (public.admin_has_permission('advertisements.review'));

create policy "Advertiser document reviewers read documents"
on public.advertiser_documents
for select to authenticated
using (public.admin_has_permission('advertiser_documents.review'));

create policy "Advertiser reviewers read advertiser records"
on public.advertisers
for select to authenticated
using (
  public.admin_has_permission('advertisers.manage')
  or public.admin_has_permission('advertiser_documents.review')
);

create policy "Advertising reviewers read order items"
on public.advertising_order_items
for select to authenticated
using (public.admin_has_permission('advertisements.review'));

create policy "Advertising reviewers read orders"
on public.advertising_orders
for select to authenticated
using (public.admin_has_permission('advertisements.review'));

-- Admins need to create short-lived signed URLs for private advertiser documents,
-- but must not gain browser-side upload/update/delete access to the bucket.
drop policy if exists "FrostTech admins manage advertiser documents" on storage.objects;
create policy "Authorised advertiser reviewers read private documents"
on storage.objects
for select to authenticated
using (
  bucket_id = 'advertiser-documents'
  and public.admin_has_permission('advertiser_documents.review')
);

-- Department-specific application review authority.
do $migration$
declare
  v_oid oid;
  v_definition text;
  v_old text;
  v_new text;
begin
  v_oid := to_regprocedure('public.admin_review_advertiser(uuid,text,text)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_review_advertiser(uuid,text,text)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN';
  v_new := 'IF auth.uid() IS NULL OR NOT public.admin_has_permission(''advertisers.manage'') THEN';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_review_advertiser(uuid,text,text)';
  end if;
  execute v_definition;

  v_oid := to_regprocedure('public.admin_review_advertiser_document(uuid,text,text)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_review_advertiser_document(uuid,text,text)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN';
  v_new := 'IF auth.uid() IS NULL OR NOT public.admin_has_permission(''advertiser_documents.review'') THEN';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_review_advertiser_document(uuid,text,text)';
  end if;
  execute v_definition;
end
$migration$;

commit;
