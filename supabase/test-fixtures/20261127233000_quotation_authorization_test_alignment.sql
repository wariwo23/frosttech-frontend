-- Isolated test-only alignment for quotation authorization regression tests.
-- Production schema is already expected to contain this private snapshot table.

begin;

create table if not exists public.admin_quotation_pricing_snapshots (
  quotation_id uuid primary key references public.admin_quotations(id) on delete cascade,
  pricing_snapshot jsonb not null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_quotation_pricing_snapshots_object_check
    check (jsonb_typeof(pricing_snapshot)='object')
);

alter table public.admin_quotation_pricing_snapshots enable row level security;
alter table public.admin_quotation_pricing_snapshots force row level security;
grant select,insert,update on public.admin_quotation_pricing_snapshots to authenticated;

insert into public.admin_role_permissions(role,permission)
values ('operations_admin','quotations.manage')
on conflict do nothing;

insert into public.admin_role_permissions(role,permission)
values ('finance_admin','quotations.read_financial')
on conflict do nothing;


-- Production RPC compatibility for the isolated regression harness.
CREATE OR REPLACE FUNCTION public.admin_create_direct_quotation_revision_v2(p_source_quotation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_source public.admin_quotations%rowtype;
  v_new public.admin_quotations%rowtype;
  v_next_version integer;
begin
  if auth.uid() is null or not public.admin_has_permission('quotations.manage') then
    raise exception 'Administrator access is required';
  end if;
  select * into v_source from public.admin_quotations
  where id=p_source_quotation_id for update;
  if not found then raise exception 'Original quotation version not found'; end if;

  if not (
    v_source.status in ('rejected','expired')
    or (v_source.status='submitted' and v_source.customer_decision in ('declined','rejected'))
  ) then
    raise exception 'Only a declined, rejected or expired quotation can be revised';
  end if;
  if exists(select 1 from public.orders where quotation_id=v_source.id) then
    raise exception 'This quotation already has an order and cannot be revised';
  end if;
  if not exists(select 1 from public.admin_quotation_pricing_snapshots where quotation_id=v_source.id) then
    raise exception 'The original private pricing inputs are unavailable. FrostTech must prepare a fresh quotation rather than guess old costs.';
  end if;
  if coalesce(v_source.additional_charges,0)>0
     and position('FROSTTECH_REQUESTED_ITEMS_V1:' in coalesce(v_source.notes,''))=0 then
    raise exception 'The original additional charges cannot be safely itemised. Prepare a fresh quotation with a complete item breakdown.';
  end if;

  perform 1 from public.quote_requests where id=v_source.request_id for update;
  select coalesce(max(version_number),0)+1 into v_next_version
  from public.admin_quotations where version_group_id=v_source.version_group_id;
  if v_source.version_number<>v_next_version-1 then
    raise exception 'A newer quotation version already exists. Create the revision from the latest version.';
  end if;

  -- subtotal and total_amount are generated from the copied commercial fields.
  insert into public.admin_quotations (
    request_id,customer_id,product_description,quantity,unit_price,
    delivery_cost,additional_charges,discount,
    validity_date,notes,status,created_by,version_group_id,version_number,
    supersedes_quotation_id,quotation_scope_snapshot
  ) values (
    v_source.request_id,v_source.customer_id,v_source.product_description,
    v_source.quantity,v_source.unit_price,v_source.delivery_cost,
    v_source.additional_charges,v_source.discount,
    v_source.validity_date,v_source.notes,'draft',
    auth.uid(),v_source.version_group_id,v_next_version,v_source.id,
    jsonb_build_object('snapshot_version',2,'state','draft_revision',
      'source_quotation_id',v_source.id,'source_version',v_source.version_number,
      'created_at',now())
  ) returning * into v_new;

  insert into public.admin_quotation_items (
    quotation_id,item_type,product_id,description,specifications,unit,
    quantity,unit_price,line_total,sort_order,source_proposal_id,replaces_item_id
  )
  select v_new.id,item_type,product_id,description,specifications,unit,
         quantity,unit_price,line_total,sort_order,source_proposal_id,replaces_item_id
  from public.admin_quotation_items
  where quotation_id=v_source.id order by sort_order,created_at;

  insert into public.admin_quotation_pricing_snapshots (
    quotation_id,pricing_snapshot,updated_by,created_at,updated_at
  )
  select v_new.id,pricing_snapshot,auth.uid(),now(),now()
  from public.admin_quotation_pricing_snapshots
  where quotation_id=v_source.id;

  return jsonb_build_object('success',true,'quotation_id',v_new.id,
    'quotation_number',v_new.quotation_number,'version_group_id',v_new.version_group_id,
    'version_number',v_new.version_number,'supersedes_quotation_id',v_source.id);
end;
$function$


commit;
