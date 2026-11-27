-- FrostTech production authorization hardening
-- Scope: direct quotation management, advertiser document removal/approval,
-- and financial detail visibility for alternative-proposal reviews.
-- Super Admin bypass is preserved by public.admin_has_permission().
-- Existing function signatures, owners, grants, trigger bindings and business logic remain intact.

begin;

insert into public.admin_role_permissions (role, permission)
values ('operations_admin', 'quotations.manage')
on conflict (role, permission) do nothing;

do $migration$
declare
  v_oid oid;
  v_definition text;
  v_old text;
  v_new text;
begin
  -- Direct quotation revision: Operations permission or Super Admin.
  v_oid := to_regprocedure('public.admin_create_direct_quotation_revision_v2(uuid)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_create_direct_quotation_revision_v2(uuid)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'if auth.uid() is null or not public.is_admin() then';
  v_new := 'if auth.uid() is null or not public.admin_has_permission(''quotations.manage'') then';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_create_direct_quotation_revision_v2(uuid)';
  end if;
  execute v_definition;

  -- Direct quotation item replacement.
  v_oid := to_regprocedure('public.admin_replace_direct_quotation_items_v2(uuid,jsonb)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_replace_direct_quotation_items_v2(uuid,jsonb)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_replace_direct_quotation_items_v2(uuid,jsonb)';
  end if;
  execute v_definition;

  -- Direct quotation submission.
  v_oid := to_regprocedure('public.admin_submit_direct_quotation(uuid)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_submit_direct_quotation(uuid)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_submit_direct_quotation(uuid)';
  end if;
  execute v_definition;

  -- Advertiser document removal: advertiser-document review permission or Super Admin.
  v_oid := to_regprocedure('public.admin_remove_advertiser_document(uuid,text)')::oid;
  if v_oid is null then raise exception 'Required function missing: admin_remove_advertiser_document(uuid,text)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'IF auth.uid() IS NULL OR NOT public.is_admin() THEN';
  v_new := 'IF auth.uid() IS NULL OR NOT public.admin_has_permission(''advertiser_documents.review'') THEN';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in admin_remove_advertiser_document(uuid,text)';
  end if;
  execute v_definition;

  -- CAC approval trigger: advertiser-management permission or Super Admin.
  v_oid := to_regprocedure('public.enforce_advertiser_cac_approval()')::oid;
  if v_oid is null then raise exception 'Required function missing: enforce_advertiser_cac_approval()'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'IF NOT public.is_admin() THEN';
  v_new := 'IF NOT public.admin_has_permission(''advertisers.manage'') THEN';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected authorization guard in enforce_advertiser_cac_approval()';
  end if;
  execute v_definition;

  -- Commercial terms are visible only to Finance-authorized users and Super Admin.
  v_oid := to_regprocedure('public.frosttech_get_request_alternative_review_v1(uuid)')::oid;
  if v_oid is null then raise exception 'Required function missing: frosttech_get_request_alternative_review_v1(uuid)'; end if;
  v_definition := pg_get_functiondef(v_oid);
  v_old := E'v_can_see_prices :=\n    coalesce(public.is_admin(), false)\n    or coalesce(public.admin_has_permission(''quotations.read_financial''), false);';
  v_new := E'v_can_see_prices :=\n    coalesce(public.admin_has_permission(''quotations.read_financial''), false);';
  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected financial-visibility rule in frosttech_get_request_alternative_review_v1(uuid)';
  end if;
  execute v_definition;
end
$migration$;

commit;
