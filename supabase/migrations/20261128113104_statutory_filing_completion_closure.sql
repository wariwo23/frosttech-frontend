
alter table public.ft_corporate_statutory_filings
  add column if not exists compliance_calendar_item_id uuid
    references public.ft_compliance_calendar_items(id) on delete restrict,
  add column if not exists completion_closed_at timestamptz,
  add column if not exists completion_closed_by uuid references auth.users(id) on delete restrict;

create unique index if not exists ft_statutory_filing_calendar_item_uidx
  on public.ft_corporate_statutory_filings(compliance_calendar_item_id)
  where compliance_calendar_item_id is not null;

create or replace function public.ft_close_statutory_filing_completion(
  p_filing_id uuid,
  p_calendar_item_id uuid default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  f public.ft_corporate_statutory_filings%rowtype;
  r public.ft_statutory_payment_reconciliations%rowtype;
  d public.ft_document_records%rowtype;
  cal public.ft_compliance_calendar_items%rowtype;
  o public.ft_compliance_obligations%rowtype;
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Super Administrator authorization required';
  end if;

  select * into f
  from public.ft_corporate_statutory_filings
  where id = p_filing_id
  for update;
  if not found then raise exception 'Statutory filing not found'; end if;
  if f.status <> 'accepted' then raise exception 'Only an officially accepted filing can be closed'; end if;
  if f.completion_closed_at is not null then raise exception 'Filing completion has already been closed'; end if;
  if length(btrim(coalesce(f.filing_reference,''))) < 3
     or length(btrim(coalesce(f.acknowledgement_reference,''))) < 3
     or f.filed_date is null
     or f.acknowledgement_document_id is null
     or f.payment_receipt_document_id is null then
    raise exception 'Official filing date, filing reference, acknowledgement reference, acknowledgement evidence and payment receipt are required';
  end if;

  select * into d from public.ft_document_records
  where id = f.acknowledgement_document_id and record_status = 'active';
  if not found then raise exception 'Acknowledgement evidence is not an active Document Vault record'; end if;

  select * into d from public.ft_document_records
  where id = f.payment_receipt_document_id and record_status = 'active';
  if not found then raise exception 'Payment receipt is not an active Document Vault record'; end if;

  select * into r
  from public.ft_statutory_payment_reconciliations
  where filing_id = f.id
    and reconciliation_status = 'matched'
    and payment_execution_id is not null
    and accounting_journal_id is not null
    and receipt_document_id = f.payment_receipt_document_id
  order by reconciled_at desc nulls last
  limit 1;
  if not found then
    raise exception 'A matched payment reconciliation linked to confirmed execution, posted accounting journal and the same receipt is required';
  end if;

  if not exists (
    select 1 from public.ft_treasury_payment_executions x
    where x.id = r.payment_execution_id and x.execution_status = 'confirmed'
      and x.evidence_document_id is not null
  ) then raise exception 'Linked treasury execution is no longer confirmed or lacks evidence'; end if;

  if not exists (
    select 1 from public.ft_bookkeeping_journals j
    where j.id = r.accounting_journal_id and j.status = 'posted'
  ) then raise exception 'Linked accounting journal is not posted'; end if;

  if f.obligation_id is not null then
    select * into o from public.ft_compliance_obligations
    where id = f.obligation_id for update;
    if not found then raise exception 'Linked compliance obligation no longer exists'; end if;
    update public.ft_compliance_obligations
      set compliance_status = 'compliant',
          evidence_document_id = f.acknowledgement_document_id,
          last_reviewed_at = now(),
          updated_at = now()
      where id = f.obligation_id;
  end if;

  if p_calendar_item_id is not null then
    select * into cal from public.ft_compliance_calendar_items
    where id = p_calendar_item_id for update;
    if not found then raise exception 'Selected compliance calendar item not found'; end if;
    if cal.status not in ('scheduled','in_progress','deferred') then
      raise exception 'Selected calendar item is not open for completion';
    end if;
    if exists(select 1 from public.ft_corporate_statutory_filings
      where compliance_calendar_item_id = p_calendar_item_id and id <> f.id) then
      raise exception 'Selected calendar item is already linked to another statutory filing';
    end if;
    update public.ft_compliance_calendar_items
      set status = 'completed',
          completion_reference = coalesce(nullif(btrim(f.acknowledgement_reference),''),f.filing_reference),
          evidence_document_id = f.acknowledgement_document_id,
          completed_at = now(),
          updated_at = now()
      where id = p_calendar_item_id;
  end if;

  update public.ft_corporate_statutory_filings
    set compliance_calendar_item_id = p_calendar_item_id,
        completion_closed_at = now(),
        completion_closed_by = auth.uid(),
        last_evidence_verified_at = now(),
        updated_at = now()
    where id = f.id;

  insert into public.ft_corporate_statutory_filing_events
    (filing_id,event_type,actor_user_id,event_note,event_snapshot)
  values
    (f.id,'filing_completion_closed',auth.uid(),
     'Statutory filing closure verified against payment reconciliation, accounting journal and official acknowledgement evidence',
     jsonb_build_object(
       'filing_reference',f.filing_reference,
       'acknowledgement_reference',f.acknowledgement_reference,
       'acknowledgement_document_id',f.acknowledgement_document_id,
       'payment_receipt_document_id',f.payment_receipt_document_id,
       'reconciliation_id',r.id,
       'payment_execution_id',r.payment_execution_id,
       'accounting_journal_id',r.accounting_journal_id,
       'compliance_obligation_id',f.obligation_id,
       'compliance_calendar_item_id',p_calendar_item_id
     ));

  return jsonb_build_object(
    'success',true,'filing_id',f.id,'reconciliation_id',r.id,
    'accounting_journal_id',r.accounting_journal_id,
    'compliance_calendar_item_id',p_calendar_item_id,
    'completion_closed_at',now()
  );
end;
$$;

revoke all on function public.ft_close_statutory_filing_completion(uuid,uuid) from public, anon;
grant execute on function public.ft_close_statutory_filing_completion(uuid,uuid) to authenticated;
