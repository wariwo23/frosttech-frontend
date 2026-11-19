-- FrostTech direct-order sourcing and finance visibility.
-- Additive review-branch migration only. Do not execute against production as part of PR review.
-- Supplier assignment and supplier costs are Super Administrator only.
-- Finance receives a separate direct-quotation ledger; existing production reconciliation is unchanged.

begin;

create table if not exists public.frosttech_direct_order_item_sourcing (
    order_item_id uuid primary key references public.order_items(id) on delete restrict,
    order_id uuid not null references public.orders(id) on delete restrict,
    supplier_id uuid not null references public.suppliers(id) on delete restrict,
    supplier_unit_cost numeric(14,2) check (supplier_unit_cost is null or supplier_unit_cost > 0),
    assigned_by uuid not null references auth.users(id) on delete restrict,
    assigned_at timestamptz not null default now(),
    costed_by uuid references auth.users(id) on delete restrict,
    costed_at timestamptz,
    assignment_note text,
    cost_note text,
    updated_at timestamptz not null default now(),
    check (
        (supplier_unit_cost is null and costed_by is null and costed_at is null)
        or
        (supplier_unit_cost is not null and costed_by is not null and costed_at is not null)
    )
);

create index if not exists frosttech_direct_order_sourcing_order_idx
    on public.frosttech_direct_order_item_sourcing(order_id,assigned_at desc);
create index if not exists frosttech_direct_order_sourcing_supplier_idx
    on public.frosttech_direct_order_item_sourcing(supplier_id,assigned_at desc);

create table if not exists public.frosttech_direct_order_sourcing_audit (
    id uuid primary key default gen_random_uuid(),
    order_id uuid not null references public.orders(id) on delete restrict,
    order_item_id uuid not null references public.order_items(id) on delete restrict,
    event_type text not null check (event_type in ('assigned','reassigned','cost_recorded','cost_updated')),
    previous_supplier_id uuid references public.suppliers(id) on delete set null,
    supplier_id uuid references public.suppliers(id) on delete set null,
    previous_unit_cost numeric(14,2),
    supplier_unit_cost numeric(14,2),
    actor_user_id uuid not null references auth.users(id) on delete restrict,
    notes text,
    created_at timestamptz not null default now()
);
create index if not exists frosttech_direct_order_sourcing_audit_item_idx
    on public.frosttech_direct_order_sourcing_audit(order_item_id,created_at desc);
create index if not exists frosttech_direct_order_sourcing_audit_order_idx
    on public.frosttech_direct_order_sourcing_audit(order_id,created_at desc);

alter table public.frosttech_direct_order_item_sourcing enable row level security;
alter table public.frosttech_direct_order_sourcing_audit enable row level security;
revoke all on public.frosttech_direct_order_item_sourcing from anon,authenticated;
revoke all on public.frosttech_direct_order_sourcing_audit from anon,authenticated;
grant all on public.frosttech_direct_order_item_sourcing to service_role;
grant all on public.frosttech_direct_order_sourcing_audit to service_role;

-- This RPC is the only client-facing read path for direct-order sourcing.
-- It deliberately checks Super Administrator status in the database.
create or replace function public.frosttech_super_admin_list_direct_order_sourcing()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $list_sourcing$
declare
    v_orders jsonb;
    v_suppliers jsonb;
begin
    if auth.uid() is null or not public.is_super_admin() then
        raise exception 'Super Administrator access is required';
    end if;

    select coalesce(jsonb_agg(
        jsonb_build_object(
            'order_id',o.id,
            'order_number',o.order_number,
            'order_status',o.status,
            'environment',o.environment,
            'customer_total',o.customer_total,
            'created_at',o.created_at,
            'item_count',(select count(*) from public.order_items oi where oi.order_id=o.id),
            'costed_item_count',(select count(*) from public.order_items oi
                join public.frosttech_direct_order_item_sourcing s on s.order_item_id=oi.id
                where oi.order_id=o.id and s.supplier_unit_cost is not null),
            'supplier_cost_total',(select coalesce(sum(s.supplier_unit_cost*oi.quantity),0)
                from public.order_items oi
                join public.frosttech_direct_order_item_sourcing s on s.order_item_id=oi.id
                where oi.order_id=o.id and s.supplier_unit_cost is not null),
            'items',coalesce((
                select jsonb_agg(jsonb_build_object(
                    'order_item_id',oi.id,
                    'product_id',oi.product_id,
                    'product_name',oi.product_name,
                    'quantity',oi.quantity,
                    'unit_price',oi.unit_price,
                    'line_total',oi.total_price,
                    'supplier_id',s.supplier_id,
                    'supplier_name',sp.business_name,
                    'supplier_unit_cost',s.supplier_unit_cost,
                    'costed_at',s.costed_at,
                    'assigned_at',s.assigned_at,
                    'assignment_note',s.assignment_note,
                    'cost_note',s.cost_note,
                    'sourcing_status',case
                        when s.order_item_id is null then 'unassigned'
                        when s.supplier_unit_cost is null then 'cost_pending'
                        else 'costed'
                    end
                ) order by oi.created_at,oi.id)
                from public.order_items oi
                left join public.frosttech_direct_order_item_sourcing s on s.order_item_id=oi.id
                left join public.suppliers sp on sp.id=s.supplier_id
                where oi.order_id=o.id
            ),'[]'::jsonb),
            'costing_status',case
                when (select count(*) from public.order_items oi where oi.order_id=o.id)=0 then 'no_items'
                when (select count(*) from public.order_items oi
                    join public.frosttech_direct_order_item_sourcing s on s.order_item_id=oi.id
                    where oi.order_id=o.id and s.supplier_unit_cost is not null)
                    = (select count(*) from public.order_items oi where oi.order_id=o.id) then 'complete'
                when exists(select 1 from public.order_items oi
                    join public.frosttech_direct_order_item_sourcing s on s.order_item_id=oi.id
                    where oi.order_id=o.id and s.supplier_unit_cost is not null) then 'partial'
                else 'pending'
            end
        ) order by o.created_at desc
    ),'[]'::jsonb) into v_orders
    from public.orders o
    where o.direct_quotation_id is not null;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id',s.id,'business_name',s.business_name,'contact_name',s.contact_name,
        'email',s.email,'phone',s.phone
    ) order by s.business_name),'[]'::jsonb)
    into v_suppliers
    from public.suppliers s
    where s.is_active is true and s.is_verified is true and s.review_status='approved';

    return jsonb_build_object('orders',v_orders,'suppliers',v_suppliers);
end;
$list_sourcing$;

revoke all on function public.frosttech_super_admin_list_direct_order_sourcing() from public,anon,authenticated;
grant execute on function public.frosttech_super_admin_list_direct_order_sourcing() to authenticated,service_role;

-- Assign one approved supplier to one direct-order line.
-- Changing the supplier invalidates the previous cost so stale costs cannot be reused.
create or replace function public.frosttech_super_admin_assign_direct_order_item_supplier(
    p_order_item_id uuid,
    p_supplier_id uuid,
    p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $assign_sourcing$
declare
    v_actor uuid:=auth.uid();
    v_order public.orders%rowtype;
    v_supplier public.suppliers%rowtype;
    v_existing public.frosttech_direct_order_item_sourcing%rowtype;
    v_event text;
begin
    if v_actor is null or not public.is_super_admin() then
        raise exception 'Super Administrator access is required';
    end if;
    if p_order_item_id is null or p_supplier_id is null or length(coalesce(p_notes,''))>1000 then
        raise exception 'A valid order item, supplier and note are required';
    end if;

    select o.* into v_order
    from public.orders o
    join public.order_items oi on oi.order_id=o.id
    where oi.id=p_order_item_id and o.direct_quotation_id is not null
    for update of o;
    if not found then raise exception 'Direct quotation order item not found'; end if;
    if v_order.status in ('pending','awaiting_payment','cancelled','delivered','completed') then
        raise exception 'Supplier assignment is not available at this order stage';
    end if;

    select s.* into v_supplier
    from public.suppliers s
    where s.id=p_supplier_id and s.is_active is true
      and s.is_verified is true and s.review_status='approved';
    if not found then raise exception 'Only active, verified and approved suppliers may be assigned'; end if;

    select * into v_existing
    from public.frosttech_direct_order_item_sourcing
    where order_item_id=p_order_item_id
    for update;

    if found and v_existing.supplier_id=p_supplier_id then
        return jsonb_build_object('success',true,'already_assigned',true,'cost_preserved',true);
    end if;

    if found then
        v_event:='reassigned';
        update public.frosttech_direct_order_item_sourcing
        set supplier_id=p_supplier_id,
            supplier_unit_cost=null,
            costed_by=null,
            costed_at=null,
            cost_note=null,
            assigned_by=v_actor,
            assigned_at=now(),
            assignment_note=nullif(btrim(coalesce(p_notes,'')),''),
            updated_at=now()
        where order_item_id=p_order_item_id;
    else
        v_event:='assigned';
        insert into public.frosttech_direct_order_item_sourcing(
            order_item_id,order_id,supplier_id,assigned_by,assignment_note
        ) values(
            p_order_item_id,v_order.id,p_supplier_id,v_actor,
            nullif(btrim(coalesce(p_notes,'')),'')
        );
    end if;

    insert into public.frosttech_direct_order_sourcing_audit(
        order_id,order_item_id,event_type,previous_supplier_id,supplier_id,
        previous_unit_cost,supplier_unit_cost,actor_user_id,notes
    ) values(
        v_order.id,p_order_item_id,v_event,
        case when v_event='reassigned' then v_existing.supplier_id else null end,
        p_supplier_id,
        case when v_event='reassigned' then v_existing.supplier_unit_cost else null end,
        null,v_actor,nullif(btrim(coalesce(p_notes,'')),'')
    );

    insert into public.admin_activity_log(actor_user_id,action,target_user_id,details)
    values(v_actor,'direct_order_item_supplier_'||v_event,null,
        jsonb_build_object('order_id',v_order.id,'order_item_id',p_order_item_id,
            'supplier_id',p_supplier_id,'previous_supplier_id',
            case when v_event='reassigned' then v_existing.supplier_id else null end));

    return jsonb_build_object('success',true,'already_assigned',false,'event',v_event,
        'cost_reset',v_event='reassigned');
end;
$assign_sourcing$;

revoke all on function public.frosttech_super_admin_assign_direct_order_item_supplier(uuid,uuid,text)
    from public,anon,authenticated;
grant execute on function public.frosttech_super_admin_assign_direct_order_item_supplier(uuid,uuid,text)
    to authenticated,service_role;

-- Supplier unit costs are entered separately from assignment and remain private.
-- These values do not update catalogue prices, order totals, orders.supplier_cost,
-- orders.frosttech_margin, or the legacy order_items.supplier_unit_cost column.
create or replace function public.frosttech_super_admin_record_direct_order_item_cost(
    p_order_item_id uuid,
    p_supplier_unit_cost numeric,
    p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $record_sourcing_cost$
declare
    v_actor uuid:=auth.uid();
    v_order public.orders%rowtype;
    v_sourcing public.frosttech_direct_order_item_sourcing%rowtype;
    v_event text;
begin
    if v_actor is null or not public.is_super_admin() then
        raise exception 'Super Administrator access is required';
    end if;
    if p_order_item_id is null or p_supplier_unit_cost is null
       or p_supplier_unit_cost<=0 or p_supplier_unit_cost>1000000000
       or length(coalesce(p_notes,''))>1000 then
        raise exception 'Enter a valid positive supplier unit cost and note';
    end if;

    select o.* into v_order
    from public.orders o
    join public.order_items oi on oi.order_id=o.id
    where oi.id=p_order_item_id and o.direct_quotation_id is not null
    for update of o;
    if not found then raise exception 'Direct quotation order item not found'; end if;
    if v_order.status in ('pending','awaiting_payment','cancelled') then
        raise exception 'Supplier costs can only be recorded after customer payment';
    end if;

    select * into v_sourcing
    from public.frosttech_direct_order_item_sourcing
    where order_item_id=p_order_item_id
    for update;
    if not found then raise exception 'Assign an approved supplier before recording its cost'; end if;

    v_event:=case when v_sourcing.supplier_unit_cost is null then 'cost_recorded' else 'cost_updated' end;

    update public.frosttech_direct_order_item_sourcing
    set supplier_unit_cost=round(p_supplier_unit_cost,2),
        costed_by=v_actor,
        costed_at=now(),
        cost_note=nullif(btrim(coalesce(p_notes,'')),''),
        updated_at=now()
    where order_item_id=p_order_item_id;

    insert into public.frosttech_direct_order_sourcing_audit(
        order_id,order_item_id,event_type,previous_supplier_id,supplier_id,
        previous_unit_cost,supplier_unit_cost,actor_user_id,notes
    ) values(
        v_order.id,p_order_item_id,v_event,v_sourcing.supplier_id,v_sourcing.supplier_id,
        v_sourcing.supplier_unit_cost,round(p_supplier_unit_cost,2),v_actor,
        nullif(btrim(coalesce(p_notes,'')),'')
    );

    insert into public.admin_activity_log(actor_user_id,action,target_user_id,details)
    values(v_actor,'direct_order_item_supplier_cost_'||v_event,null,
        jsonb_build_object('order_id',v_order.id,'order_item_id',p_order_item_id,
            'supplier_id',v_sourcing.supplier_id,
            'previous_unit_cost',v_sourcing.supplier_unit_cost,
            'supplier_unit_cost',round(p_supplier_unit_cost,2)));

    return jsonb_build_object('success',true,'event',v_event,'supplier_unit_cost',round(p_supplier_unit_cost,2));
end;
$record_sourcing_cost$;

revoke all on function public.frosttech_super_admin_record_direct_order_item_cost(uuid,numeric,text)
    from public,anon,authenticated;
grant execute on function public.frosttech_super_admin_record_direct_order_item_cost(uuid,numeric,text)
    to authenticated,service_role;

-- Separate Finance ledger. It reports direct quotations and their payment attempts,
-- preserving each environment. Supplier assignments, supplier costs and margins are never returned.
create or replace function public.finance_list_direct_quotation_activity(
    p_start_date date,
    p_end_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $direct_finance$
declare
    v_rows jsonb;
begin
    if auth.uid() is null or not public.admin_has_permission('quotations.read_financial') then
        raise exception 'Financial quotation-read permission required';
    end if;
    if p_start_date is null or p_end_date is null or p_end_date<p_start_date then
        raise exception 'Invalid reporting period';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'quotation_id',q.id,
        'quotation_number',q.quotation_number,
        'customer_name',q.customer_name,
        'customer_email',q.customer_email,
        'status',q.status,
        'environment',q.environment,
        'subtotal',q.subtotal,
        'additional_charges',q.additional_charges,
        'discount',q.discount,
        'delivery_cost',q.delivery_cost,
        'administration_fee',q.administration_fee,
        'total_amount',q.total_amount,
        'fee_status',q.fee_status,
        'created_at',q.created_at,
        'submitted_at',q.submitted_at,
        'decision_at',q.decision_at,
        'order',case when o.id is null then null else jsonb_build_object(
            'order_id',o.id,
            'order_number',o.order_number,
            'order_status',o.status,
            'customer_total',o.customer_total,
            'created_at',o.created_at,
            'payments',coalesce((
                select jsonb_agg(jsonb_build_object(
                    'payment_id',p.id,'amount',p.amount,'currency',p.currency,
                    'payment_method',p.payment_method,'reference',p.transaction_reference,
                    'status',p.status,'environment',p.environment,
                    'created_at',p.created_at,'paid_at',p.paid_at
                ) order by p.created_at desc)
                from public.payments p where p.order_id=o.id
            ),'[]'::jsonb)
        ) end,
        'fee_payments',coalesce((
            select jsonb_agg(jsonb_build_object(
                'payment_id',fp.id,'amount',fp.amount,'currency',fp.currency,
                'reference',fp.provider_reference,'status',fp.status,
                'environment',fp.environment,'created_at',fp.created_at,
                'verified_at',fp.verified_at
            ) order by fp.created_at desc)
            from public.frosttech_direct_quote_fee_payments fp
            where fp.direct_quotation_id=q.id
        ),'[]'::jsonb)
    ) order by q.created_at desc),'[]'::jsonb) into v_rows
    from public.frosttech_direct_quotations q
    left join public.orders o on o.direct_quotation_id=q.id
    where q.created_at >= p_start_date::timestamp at time zone 'Africa/Lagos'
      and q.created_at < (p_end_date+1)::timestamp at time zone 'Africa/Lagos';

    return v_rows;
end;
$direct_finance$;

revoke all on function public.finance_list_direct_quotation_activity(date,date)
    from public,anon,authenticated;
grant execute on function public.finance_list_direct_quotation_activity(date,date)
    to authenticated,service_role;

create or replace function public.frosttech_reject_direct_order_sourcing_audit_mutation()
returns trigger
language plpgsql
set search_path=''
as $sourcing_audit$
begin
    raise exception 'Direct-order sourcing audit records are immutable';
end;
$sourcing_audit$;

drop trigger if exists frosttech_direct_order_sourcing_audit_immutable
    on public.frosttech_direct_order_sourcing_audit;
create trigger frosttech_direct_order_sourcing_audit_immutable
    before update or delete on public.frosttech_direct_order_sourcing_audit
    for each row execute function public.frosttech_reject_direct_order_sourcing_audit_mutation();
revoke all on function public.frosttech_reject_direct_order_sourcing_audit_mutation()
    from public,anon,authenticated;
grant execute on function public.frosttech_reject_direct_order_sourcing_audit_mutation()
    to service_role;

comment on table public.frosttech_direct_order_item_sourcing is
    'Per-order-item supplier assignments and private supplier unit costs for independent direct-quotation orders. Super Administrator only.';
comment on table public.frosttech_direct_order_sourcing_audit is
    'Append-only audit history for direct-order supplier assignment and supplier cost changes.';
comment on function public.finance_list_direct_quotation_activity(date,date) is
    'Separate Finance view of direct quotations and payment attempts by environment; excludes supplier costs and margin.';

commit;
