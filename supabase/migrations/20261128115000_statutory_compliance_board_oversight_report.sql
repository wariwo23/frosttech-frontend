create or replace view public.ft_statutory_compliance_board_report_v
with (security_invoker = true)
as
select m.filing_id,f.filing_type,f.authority_name,f.reporting_period_start,f.reporting_period_end,
 m.due_date,m.filed_date,m.filing_status,m.monitoring_status,f.fee_amount,
 f.filing_reference,f.payment_reference,m.acknowledgement_reference,
 m.payment_reconciliation_status,m.payment_execution_id,m.accounting_journal_id,
 m.has_filing_reference,m.has_acknowledgement_reference,m.has_active_acknowledgement,
 m.has_active_payment_receipt,m.completion_closed_at,m.obligation_id,m.obligation_ref,
 m.obligation_name,m.applicability_status,m.compliance_status,m.calendar_ref,
 coalesce(e.escalation_count,0) escalation_count,e.latest_escalation_at,
 coalesce(e.risk_types,array[]::text[]) risk_types,f.responsible_user_id,f.submitted_by,f.updated_at
from public.ft_statutory_filing_monitoring_v m
join public.ft_corporate_statutory_filings f on f.id=m.filing_id
left join lateral (
 select count(*)::integer escalation_count,max(x.created_at) latest_escalation_at,
 array_agg(distinct x.risk_type order by x.risk_type) risk_types
 from public.ft_statutory_risk_escalation_log x where x.filing_id=m.filing_id
) e on true;
revoke all on public.ft_statutory_compliance_board_report_v from public,anon;
grant select on public.ft_statutory_compliance_board_report_v to authenticated;