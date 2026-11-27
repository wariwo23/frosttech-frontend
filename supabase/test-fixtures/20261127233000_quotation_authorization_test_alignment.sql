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


-- Remaining production RPC compatibility definitions.
CREATE OR REPLACE FUNCTION public.admin_replace_direct_quotation_items_v2(p_quotation_id uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_quote public.admin_quotations%rowtype;
  v_count integer;
  v_total numeric;
  v_expected numeric;
  v_accepted_proposal uuid;
  v_proposal_payload jsonb;
  v_linked_count integer;
begin
  if auth.uid() is null or not public.admin_has_permission('quotations.manage') then
    raise exception 'Administrator access is required';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'At least one quotation item is required';
  end if;

  select * into v_quote from public.admin_quotations
  where id=p_quotation_id for update;
  if not found or v_quote.status<>'draft' then
    raise exception 'Only a saved draft quotation can have its items changed';
  end if;

  select d.proposal_id,p.proposed_payload
  into v_accepted_proposal,v_proposal_payload
  from public.alternative_proposal_decisions d
  join public.alternative_proposals p on p.id=d.proposal_id
  where d.request_id=v_quote.request_id and d.decision='accepted';

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      item_type text,product_id uuid,description text,specifications jsonb,
      unit text,quantity numeric,unit_price numeric,sort_order integer,
      source_proposal_id uuid,replaces_item_id uuid
    )
    where coalesce(btrim(x.description),'')=''
       or coalesce(btrim(x.unit),'')=''
       or x.item_type not in ('product','service','accessory','installation','delivery','other')
       or x.quantity is null or x.quantity<=0
       or x.unit_price is null or x.unit_price<0
       or coalesce(x.sort_order,0)<0
       or (x.specifications is not null and jsonb_typeof(x.specifications)<>'object')
  ) then
    raise exception 'One or more quotation items contain invalid details';
  end if;

  select count(*),coalesce(sum(round(x.quantity*x.unit_price,2)),0)
  into v_count,v_total
  from jsonb_to_recordset(p_items) as x(
    item_type text,product_id uuid,description text,specifications jsonb,
    unit text,quantity numeric,unit_price numeric,sort_order integer,
    source_proposal_id uuid,replaces_item_id uuid
  );

  v_expected:=coalesce(v_quote.subtotal,v_quote.unit_price*v_quote.quantity)
              +coalesce(v_quote.additional_charges,0);
  if v_count=0 or round(v_total,2)<>round(v_expected,2) then
    raise exception 'Quotation item totals (%) must equal product subtotal plus additional charges (%)',v_total,v_expected;
  end if;

  if v_accepted_proposal is not null then
    select count(*) into v_linked_count
    from jsonb_to_recordset(p_items) as x(
      item_type text,product_id uuid,description text,specifications jsonb,
      unit text,quantity numeric,unit_price numeric,sort_order integer,
      source_proposal_id uuid,replaces_item_id uuid
    )
    where x.source_proposal_id=v_accepted_proposal
       or (
         x.source_proposal_id is null
         and lower(btrim(x.description)) in (
           lower(btrim(coalesce(v_proposal_payload->>'title',''))),
           lower(btrim(coalesce(v_proposal_payload->>'description','')))
         )
       );

    if v_linked_count<>1 then
      raise exception 'The customer-approved alternative must appear exactly once as a quotation item, using its approved description';
    end if;
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      item_type text,product_id uuid,description text,specifications jsonb,
      unit text,quantity numeric,unit_price numeric,sort_order integer,
      source_proposal_id uuid,replaces_item_id uuid
    )
    where x.source_proposal_id is not null
      and not exists (
        select 1 from public.alternative_proposal_decisions d
        where d.proposal_id=x.source_proposal_id
          and d.request_id=v_quote.request_id and d.decision='accepted'
      )
  ) then
    raise exception 'Only a customer-accepted alternative proposal may be linked to a quotation item';
  end if;

  delete from public.admin_quotation_items where quotation_id=v_quote.id;

  insert into public.admin_quotation_items (
    quotation_id,item_type,product_id,description,specifications,unit,
    quantity,unit_price,line_total,sort_order,source_proposal_id,replaces_item_id
  )
  select
    v_quote.id,x.item_type,x.product_id,btrim(x.description),
    coalesce(x.specifications,'{}'::jsonb),btrim(x.unit),x.quantity,
    x.unit_price,round(x.quantity*x.unit_price,2),coalesce(x.sort_order,0),
    coalesce(x.source_proposal_id,
      case when v_accepted_proposal is not null
        and lower(btrim(x.description)) in (
          lower(btrim(coalesce(v_proposal_payload->>'title',''))),
          lower(btrim(coalesce(v_proposal_payload->>'description','')))
        ) then v_accepted_proposal else null end
    ),
    x.replaces_item_id
  from jsonb_to_recordset(p_items) as x(
    item_type text,product_id uuid,description text,specifications jsonb,
    unit text,quantity numeric,unit_price numeric,sort_order integer,
    source_proposal_id uuid,replaces_item_id uuid
  )
  order by coalesce(x.sort_order,0);

  return jsonb_build_object('success',true,'quotation_id',v_quote.id,
    'item_count',v_count,'items_total',round(v_total,2));
end;
$function$


CREATE OR REPLACE FUNCTION public.admin_submit_direct_quotation(p_quotation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_quote public.admin_quotations%rowtype;
  v_request public.quote_requests%rowtype;
  v_subtotal numeric;
  v_additional numeric;
  v_discount numeric;
  v_delivery numeric;
  v_total numeric;
  v_fee_basis numeric;
  v_fee numeric;
  v_item_total numeric;
  v_item_count integer;
  v_is_fee_paid boolean;
  v_snapshot jsonb;
  v_accepted_proposal uuid;
begin
  if auth.uid() is null or not public.admin_has_permission('quotations.manage') then
    raise exception 'Administrator access is required';
  end if;

  select * into v_quote from public.admin_quotations
  where id=p_quotation_id for update;
  if not found then raise exception 'Quotation not found'; end if;
  if v_quote.status<>'draft' then raise exception 'Only a draft quotation can be submitted'; end if;

  select * into v_request from public.quote_requests
  where id=v_quote.request_id for update;
  if not found then raise exception 'Linked customer request not found'; end if;
  if v_quote.customer_id is distinct from v_request.customer_id then
    raise exception 'Quotation and request ownership do not match';
  end if;
  if v_request.status not in ('pending','in_progress','quoted') then
    raise exception 'This customer request is not in a state that allows a quotation';
  end if;

  if exists (
    select 1 from public.admin_quotations other_quote
    where other_quote.request_id=v_request.id and other_quote.id<>v_quote.id
      and (
        other_quote.status='accepted'
        or (other_quote.status='submitted'
            and coalesce(other_quote.customer_decision,'') not in ('declined','rejected'))
      )
  ) then
    raise exception 'Another quotation is still awaiting a customer decision or has been accepted';
  end if;

  v_subtotal:=v_quote.subtotal;
  v_additional:=coalesce(v_quote.additional_charges,0);
  v_discount:=coalesce(v_quote.discount,0);
  v_delivery:=coalesce(v_quote.delivery_cost,0);
  if v_subtotal<=0 or v_additional<0 or v_discount<0
     or v_discount>v_subtotal+v_additional or v_delivery<0 then
    raise exception 'Quotation amounts are invalid';
  end if;

  v_total:=v_quote.total_amount;
  -- Administration fee excludes delivery entirely.
  v_fee_basis:=v_subtotal+v_additional-v_discount;
  if v_fee_basis<=0 then raise exception 'Quotation administration-fee basis must be greater than zero'; end if;

  select count(*),coalesce(sum(line_total),0)
  into v_item_count,v_item_total
  from public.admin_quotation_items where quotation_id=v_quote.id;
  if v_item_count=0 or round(v_item_total,2)<>round(v_subtotal+v_additional,2) then
    raise exception 'Quotation item breakdown does not match the saved product subtotal and additional charges';
  end if;

  select d.proposal_id into v_accepted_proposal
  from public.alternative_proposal_decisions d
  where d.request_id=v_quote.request_id and d.decision='accepted';

  if v_accepted_proposal is not null and not exists (
    select 1 from public.admin_quotation_items i
    where i.quotation_id=v_quote.id and i.source_proposal_id=v_accepted_proposal
  ) then
    raise exception 'The customer-approved alternative must be included in the quotation version before submission';
  end if;

  if exists (
    select 1 from public.admin_quotation_items i
    where i.quotation_id=v_quote.id and i.source_proposal_id is not null
      and not exists (
        select 1 from public.alternative_proposal_decisions d
        where d.proposal_id=i.source_proposal_id and d.request_id=v_quote.request_id
          and d.decision='accepted'
      )
  ) then
    raise exception 'Only customer-accepted alternative proposals may be included in approved quotation items';
  end if;

  v_is_fee_paid:=lower(coalesce(v_request.admin_fee_status,''))='paid'
    and v_request.admin_fee_paid_at is not null;
  if not v_is_fee_paid
     and nullif(btrim(coalesce(v_request.admin_fee_transaction_reference,'')),'') is not null then
    raise exception 'A previous administration-fee payment attempt must be reconciled before submitting a revised quotation';
  end if;

  if v_is_fee_paid then
    v_fee:=v_request.admin_fee;
    if v_fee is null or v_fee<=0 then
      raise exception 'The recorded administration-fee payment requires administrator reconciliation';
    end if;
  else
    v_fee:=round(v_fee_basis*0.02,2);
  end if;

  v_snapshot:=jsonb_build_object(
    'snapshot_version',2,
    'quotation_id',v_quote.id,
    'quotation_number',v_quote.quotation_number,
    'version_group_id',v_quote.version_group_id,
    'version_number',v_quote.version_number,
    'supersedes_quotation_id',v_quote.supersedes_quotation_id,
    'request_id',v_quote.request_id,
    'customer_id',v_quote.customer_id,
    'items',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'item_id',i.id,'item_type',i.item_type,'product_id',i.product_id,
        'description',i.description,'specifications',i.specifications,
        'unit',i.unit,'quantity',i.quantity,'unit_price',i.unit_price,
        'line_total',i.line_total,'source_proposal_id',i.source_proposal_id,
        'replaces_item_id',i.replaces_item_id
      ) order by i.sort_order,i.created_at),'[]'::jsonb)
      from public.admin_quotation_items i where i.quotation_id=v_quote.id
    ),
    'subtotal',v_subtotal,'additional_charges',v_additional,
    'discount',v_discount,'delivery_cost',v_delivery,'total_amount',v_total,
    'validity_date',v_quote.validity_date,'customer_notes',v_quote.notes,
    'original_request_snapshot',(
      select jsonb_build_object(
        'capture_type',s.capture_type,
        'payload_hash',s.payload_hash,
        'captured_at',s.captured_at,
        'original_payload',s.original_payload
      )
      from public.quote_request_original_snapshots s
      where s.request_id=v_quote.request_id
    ),
    'accepted_alternative',(
      select jsonb_build_object(
        'proposal_id',p.id,
        'proposer_type',p.proposer_type,
        'reason',p.reason,
        'proposed_payload',p.proposed_payload,
        'commercial_terms',p.commercial_terms,
        'decision',d.decision,
        'decided_at',d.decided_at
      )
      from public.alternative_proposals p
      join public.alternative_proposal_decisions d on d.proposal_id=p.id
      where p.id=v_accepted_proposal
    ),
    'captured_at',now()
  );

  -- subtotal and total_amount are generated columns; never write to them.
  update public.admin_quotations
  set quotation_scope_snapshot=v_snapshot,
      submitted_scope_snapshot=v_snapshot,
      status='submitted',updated_at=now()
  where id=v_quote.id returning * into v_quote;

  if v_is_fee_paid then
    update public.quote_requests set status='quoted',updated_at=now()
    where id=v_request.id;
  else
    update public.quote_requests set status='quoted',admin_fee=v_fee,
      admin_fee_status='pending',updated_at=now()
    where id=v_request.id;
  end if;

  return jsonb_build_object(
    'quotation_id',v_quote.id,'request_id',v_quote.request_id,
    'quotation_number',v_quote.quotation_number,
    'version_group_id',v_quote.version_group_id,'version_number',v_quote.version_number,
    'fee',v_fee,'fee_already_paid',v_is_fee_paid,
    'subtotal',v_subtotal,'total_amount',v_total,'status',v_quote.status
  );
end;
$function$


CREATE OR REPLACE FUNCTION public.frosttech_get_request_alternative_review_v1(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_can_see_prices boolean;
  v_result jsonb;
begin
  if not public.frosttech_can_manage_customer_requests_v1() then
    raise exception 'Customer request management permission is required';
  end if;

  if not exists (select 1 from public.quote_requests q where q.id = p_request_id) then
    raise exception 'Customer request was not found';
  end if;

  v_can_see_prices :=
    coalesce(public.admin_has_permission('quotations.read_financial'), false);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'proposer_type', a.proposer_type,
    'supplier_id', a.supplier_id,
    'supplier_quote_id', a.supplier_quote_id,
    'admin_quotation_id', a.admin_quotation_id,
    'version_number', a.version_number,
    'reason', a.reason,
    'proposed_payload', a.proposed_payload,
    'commercial_terms', case
      when v_can_see_prices then a.commercial_terms
      else jsonb_build_object('pricing_locked',true)
    end,
    'differences', a.differences,
    'submitted_at', a.submitted_at,
    'decision', d.decision,
    'decision_reason', d.decision_reason,
    'decided_at', d.decided_at
  ) order by a.submitted_at desc), '[]'::jsonb)
  into v_result
  from public.alternative_proposals a
  left join public.alternative_proposal_decisions d
    on d.proposal_id = a.id
  where a.request_id = p_request_id;

  return v_result;
end;
$function$


commit;
