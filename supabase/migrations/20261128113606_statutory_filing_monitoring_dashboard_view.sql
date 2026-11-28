create or replace view public.ft_statutory_filing_monitoring_v
with (security_invoker = true)
as
select
 f.id as filing_id,
 f.filing_type,
 f.authority_name,
 f.due_date,
 f.filed_date,
 f.status as filing_status,
 f.filing_reference,
 f.acknowledgement_reference,
 f.completion_closed_at,
 f.obligation_id,
 o.obligation_ref,
 o.obligation_name,
 o.applicability_status,
 o.compliance_status,
 f.compliance_calendar_item_id,
 c.calendar_ref,
 c.status as calendar_status,
 case
  when f.completion_closed_at is not null then 'completed'
  when f.status = 'accepted' then 'accepted_awaiting_closure'
  when f.status in ('submitted','filed') then 'awaiting_acknowledgement'
  when f.due_date < current_date then 'overdue'
  when f.due_date <= current_date + 30 then 'due_within_30_days'
  else 'upcoming'
 end as monitoring_status,
 (f.filing_reference is not null and length(btrim(f.filing_reference)) >= 3) as has_filing_reference,
 (f.acknowledgement_reference is not null and length(btrim(f.acknowledgement_reference)) >= 3) as has_acknowledgement_reference,
 exists(select 1 from public.ft_document_records d where d.id=f.acknowledgement_document_id and d.record_status='active') as has_active_acknowledgement,
 exists(select 1 from public.ft_document_records d where d.id=f.payment_receipt_document_id and d.record_status='active') as has_active_payment_receipt,
 coalesce(r.reconciliation_status,'not_reconciled') as payment_reconciliation_status,
 r.payment_execution_id,
 r.accounting_journal_id,
 r.id as reconciliation_id,
 f.updated_at
from public.ft_corporate_statutory_filings f
left join public.ft_compliance_obligations o on o.id=f.obligation_id
left join public.ft_compliance_calendar_items c on c.id=f.compliance_calendar_item_id
left join lateral (
 select x.id,x.reconciliation_status,x.payment_execution_id,x.accounting_journal_id
 from public.ft_statutory_payment_reconciliations x
 where x.filing_id=f.id
 order by x.reconciled_at desc nulls last,x.created_at desc
 limit 1
) r on true;
revoke all on public.ft_statutory_filing_monitoring_v from public,anon;
grant select on public.ft_statutory_filing_monitoring_v to authenticated;