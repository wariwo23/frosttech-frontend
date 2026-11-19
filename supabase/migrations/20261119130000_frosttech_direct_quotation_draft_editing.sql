-- Allow an authorised operator to revise only their own unsent direct-quotation drafts.
-- Issued, accepted, declined and expired quotations remain immutable.
begin;

create or replace function public.frosttech_update_direct_quotation_draft(
    p_quote_id uuid,
    p_header jsonb,
    p_items jsonb,
    p_actor uuid
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $update_draft$
declare
    v_role text;
    v_quote public.frosttech_direct_quotations%rowtype;
    v_item jsonb;
    v_line integer:=0;
    v_sum numeric(14,2):=0;
    v_quantity numeric(14,3);
    v_unit_price numeric(14,2);
    v_line_total numeric(14,2);
    v_item_type text;
    v_product_id uuid;
    v_description text;
    v_unit text;
    v_subtotal numeric(14,2);
    v_additional numeric(14,2);
    v_discount numeric(14,2);
    v_delivery numeric(14,2);
    v_total numeric(14,2);
    v_customer_id uuid;
    v_email text;
    v_customer_name text;
begin
    if p_quote_id is null or p_actor is null or p_header is null
       or jsonb_typeof(p_header)<>'object' or p_items is null
       or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1
       or jsonb_array_length(p_items)>100 then
        raise exception 'Invalid direct quotation draft update';
    end if;

    select a.role into v_role
    from public.admin_accounts a
    join public.profiles p on p.id=a.user_id
    where a.user_id=p_actor and a.is_active is true and p.is_active is true
      and a.role in ('super_admin','operations_admin');
    if v_role is null then raise exception 'Super Administrator or Operations Administrator access is required'; end if;

    select * into v_quote
    from public.frosttech_direct_quotations
    where id=p_quote_id and created_by=p_actor
    for update;
    if not found or v_quote.status<>'draft' then
        raise exception 'Only your own unsent quotation draft can be edited';
    end if;

    v_email:=lower(btrim(coalesce(p_header->>'customer_email','')));
    v_customer_name:=btrim(coalesce(p_header->>'customer_name',''));
    if position('@' in v_email)<=1 or position('.' in split_part(v_email,'@',2))<=1
       or position(' ' in v_email)>0 or v_customer_name='' or length(v_customer_name)>160 then
        raise exception 'Valid customer name and email are required';
    end if;

    v_customer_id:=nullif(p_header->>'customer_id','')::uuid;
    if v_customer_id is not null and not exists(
        select 1 from public.customers c where c.id=v_customer_id
          and lower(btrim(coalesce(c.email,'')))=v_email
    ) then raise exception 'Selected customer email does not match the registered customer'; end if;

    v_subtotal:=coalesce((p_header->>'subtotal')::numeric,-1);
    v_additional:=coalesce((p_header->>'additional_charges')::numeric,-1);
    v_discount:=coalesce((p_header->>'discount')::numeric,-1);
    v_delivery:=coalesce((p_header->>'delivery_cost')::numeric,-1);
    if v_subtotal<0 or v_additional<0 or v_discount<0 or v_delivery<0
       or v_discount>v_subtotal+v_additional then
        raise exception 'Quotation amounts are invalid';
    end if;

    for v_item in select value from jsonb_array_elements(p_items) loop
        v_line:=v_line+1;
        v_item_type:=lower(coalesce(v_item->>'item_type',''));
        v_description:=btrim(coalesce(v_item->>'description',''));
        v_unit:=btrim(coalesce(v_item->>'unit','unit'));
        v_quantity:=(v_item->>'quantity')::numeric;
        v_unit_price:=(v_item->>'unit_price')::numeric;
        v_line_total:=(v_item->>'line_total')::numeric;
        v_product_id:=nullif(v_item->>'product_id','')::uuid;
        if v_item_type not in ('product','service','accessory','installation','other')
           or v_description='' or length(v_description)>500 or v_unit='' or length(v_unit)>40
           or v_quantity<=0 or v_quantity>1000000 or v_unit_price<0
           or v_line_total<>round(v_quantity*v_unit_price,2) then
            raise exception 'Quotation item % is invalid',v_line;
        end if;
        if v_item_type='product' then
            if v_product_id is null or not exists(
                select 1 from public.products p where p.id=v_product_id and p.is_active is true
            ) then raise exception 'Active catalogue product required for item %',v_line; end if;
        elsif v_product_id is not null then
            raise exception 'Only product lines may reference a catalogue product';
        end if;
        v_sum:=v_sum+v_line_total;
        if v_sum>1000000000 then raise exception 'Quotation subtotal exceeds permitted limit'; end if;
    end loop;

    if v_sum<>v_subtotal then raise exception 'Quotation item totals do not equal submitted subtotal'; end if;
    v_total:=round(v_subtotal+v_additional-v_discount+v_delivery,2);

    update public.frosttech_direct_quotations
    set customer_id=v_customer_id,
        customer_name=v_customer_name,
        customer_email=v_email,
        customer_phone=nullif(btrim(coalesce(p_header->>'customer_phone','')),''),
        subtotal=v_subtotal,
        additional_charges=v_additional,
        discount=v_discount,
        delivery_cost=v_delivery,
        total_amount=v_total,
        validity_expires_at=nullif(p_header->>'validity_expires_at','')::timestamptz,
        customer_message=nullif(p_header->>'customer_message',''),
        internal_note=nullif(p_header->>'internal_note',''),
        updated_at=now()
    where id=p_quote_id
    returning * into v_quote;

    delete from public.frosttech_direct_quotation_items
    where direct_quotation_id=p_quote_id;

    v_line:=0;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_line:=v_line+1;
        insert into public.frosttech_direct_quotation_items(
            direct_quotation_id,line_number,item_type,product_id,description,quantity,unit,unit_price,line_total
        ) values(
            p_quote_id,v_line,lower(v_item->>'item_type'),nullif(v_item->>'product_id','')::uuid,
            btrim(v_item->>'description'),(v_item->>'quantity')::numeric,
            coalesce(nullif(btrim(v_item->>'unit'),''),'unit'),
            (v_item->>'unit_price')::numeric,(v_item->>'line_total')::numeric
        );
    end loop;

    insert into public.admin_activity_log(actor_user_id,action,target_user_id,details)
    values(p_actor,'direct_quotation_draft_updated',null,
        jsonb_build_object('direct_quotation_id',p_quote_id,
            'quotation_number',v_quote.quotation_number,
            'customer_email',v_email,'item_count',v_line,'environment',v_quote.environment));

    return jsonb_build_object('id',v_quote.id,'quotation_number',v_quote.quotation_number,
        'status',v_quote.status,'subtotal',v_quote.subtotal,
        'additional_charges',v_quote.additional_charges,'discount',v_quote.discount,
        'delivery_cost',v_quote.delivery_cost,'total_amount',v_quote.total_amount,
        'environment',v_quote.environment,'item_count',v_line);
end;
$update_draft$;

revoke all on function public.frosttech_update_direct_quotation_draft(uuid,jsonb,jsonb,uuid)
    from public,anon,authenticated;
grant execute on function public.frosttech_update_direct_quotation_draft(uuid,jsonb,jsonb,uuid)
    to service_role;

commit;
