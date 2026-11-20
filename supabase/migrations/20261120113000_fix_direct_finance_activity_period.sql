-- Finance reporting period includes direct-quotation activity, not only quotation creation.
-- A later payment or receipt must remain visible even when the quotation was created earlier.
begin;

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
    v_period_start timestamptz := p_start_date::timestamp at time zone 'Africa/Lagos';
    v_period_end timestamptz := (p_end_date + 1)::timestamp at time zone 'Africa/Lagos';
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
        ),'[]'::jsonb),
        'receipts',coalesce((
            select jsonb_agg(jsonb_build_object(
                'receipt_number',r.receipt_number,
                'receipt_type',r.receipt_type,
                'payment_reference',r.payment_reference,
                'amount_received',r.amount_received,
                'payment_status',r.payment_status,
                'environment',r.environment,
                'paid_at',r.paid_at
            ) order by r.paid_at desc)
            from public.payment_receipts r
            where r.direct_quotation_id=q.id
               or (o.id is not null and r.order_id=o.id::text)
        ),'[]'::jsonb)
    ) order by greatest(q.created_at,coalesce(o.created_at,q.created_at)) desc),'[]'::jsonb) into v_rows
    from public.frosttech_direct_quotations q
    left join public.orders o on o.direct_quotation_id=q.id
    where (
        (q.created_at >= v_period_start and q.created_at < v_period_end)
        or (q.submitted_at >= v_period_start and q.submitted_at < v_period_end)
        or (q.decision_at >= v_period_start and q.decision_at < v_period_end)
        or (o.created_at >= v_period_start and o.created_at < v_period_end)
        or exists (
            select 1 from public.frosttech_direct_quote_fee_payments fp
            where fp.direct_quotation_id=q.id
              and ((fp.created_at >= v_period_start and fp.created_at < v_period_end)
                or (fp.verified_at >= v_period_start and fp.verified_at < v_period_end))
        )
        or exists (
            select 1 from public.payments p
            where p.order_id=o.id
              and ((p.created_at >= v_period_start and p.created_at < v_period_end)
                or (p.paid_at >= v_period_start and p.paid_at < v_period_end))
        )
        or exists (
            select 1 from public.payment_receipts r
            where (r.direct_quotation_id=q.id or (o.id is not null and r.order_id=o.id::text))
              and r.paid_at >= v_period_start and r.paid_at < v_period_end
        )
    );

    return v_rows;
end;
$direct_finance$;

commit;
