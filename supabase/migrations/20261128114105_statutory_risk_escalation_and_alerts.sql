create table if not exists public.ft_statutory_risk_escalation_log (
 id uuid primary key default gen_random_uuid(),
 filing_id uuid not null references public.ft_corporate_statutory_filings(id) on delete restrict,
 risk_type text not null check (risk_type in ('overdue_filing','missing_acknowledgement','payment_reconciliation_variance','missing_payment_reconciliation')),
 escalation_stage text not null,
 recipient_user_id uuid not null references auth.users(id) on delete restrict,
 reason text not null,
 notification_id uuid references public.notifications(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(filing_id,risk_type,escalation_stage,recipient_user_id)
);
create index if not exists ft_stat_risk_escalation_created_idx on public.ft_statutory_risk_escalation_log(created_at desc);
alter table public.ft_statutory_risk_escalation_log enable row level security;
revoke all on public.ft_statutory_risk_escalation_log from public,anon,authenticated;
grant select on public.ft_statutory_risk_escalation_log to authenticated;
drop policy if exists ft_stat_risk_escalation_super_read on public.ft_statutory_risk_escalation_log;
create policy ft_stat_risk_escalation_super_read on public.ft_statutory_risk_escalation_log for select to authenticated using (public.is_super_admin());
create or replace function public.ft_process_statutory_risk_escalations()
returns jsonb language plpgsql security definer set search_path='public','pg_temp' as $$
declare r record;v_admin uuid;v_recipient uuid;v_stage text;v_reason text;v_risk text;v_inserted integer:=0;v_notification uuid;v_recipients uuid[];v_user uuid;
begin
 if auth.uid() is not null and not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 select id into v_admin from auth.users where lower(email)='unajite@yahoo.com' limit 1;
 if v_admin is null then raise exception 'Super Administrator account is not available'; end if;
 for r in select * from public.ft_statutory_filing_monitoring_v where filing_status not in ('not_applicable','cancelled') loop
  v_risk:=null;v_stage:=null;v_reason:=null;
  if r.completion_closed_at is null and r.due_date is not null and r.due_date<current_date then
   v_risk:='overdue_filing';
   v_stage:=case when current_date-r.due_date>=30 then 'overdue_30' when current_date-r.due_date>=14 then 'overdue_14' when current_date-r.due_date>=7 then 'overdue_7' when current_date-r.due_date>=3 then 'overdue_3' else 'overdue_1' end;
   v_reason:=format('Statutory filing %s for %s is %s day(s) overdue. Due date: %s.',r.filing_type,r.authority_name,current_date-r.due_date,r.due_date);
  elsif r.filing_status='accepted' and r.completion_closed_at is null and (not r.has_acknowledgement_reference or not r.has_active_acknowledgement or not r.has_active_payment_receipt or r.payment_reconciliation_status<>'matched' or r.accounting_journal_id is null) then
   v_risk:='missing_acknowledgement';v_stage:='accepted_missing_closure_evidence';
   v_reason:=format('Accepted statutory filing %s for %s is not closure-ready: acknowledgement, receipt, matched payment or posted-journal linkage is missing.',r.filing_type,r.authority_name);
  elsif r.payment_reconciliation_status='variance' then
   v_risk:='payment_reconciliation_variance';v_stage:='unresolved_variance';
   v_reason:=format('Statutory filing %s for %s has an unresolved payment reconciliation variance.',r.filing_type,r.authority_name);
  elsif r.payment_reconciliation_status='not_reconciled' and r.filing_status in ('submitted','filed','accepted') and r.filed_date is not null then
   v_risk:='missing_payment_reconciliation';v_stage:='submitted_without_reconciliation';
   v_reason:=format('Statutory filing %s for %s has been submitted but has no recorded payment reconciliation.',r.filing_type,r.authority_name);
  end if;
  if v_risk is null then continue; end if;
  v_recipients:=array[v_admin];
  if r.obligation_id is not null then select responsible_user_id into v_recipient from public.ft_compliance_obligations where id=r.obligation_id; else v_recipient:=null; end if;
  if v_recipient is null then select responsible_user_id into v_recipient from public.ft_corporate_statutory_filings where id=r.filing_id; end if;
  if v_recipient is not null and v_recipient<>v_admin then v_recipients:=array_append(v_recipients,v_recipient); end if;
  foreach v_user in array v_recipients loop
   insert into public.ft_statutory_risk_escalation_log(filing_id,risk_type,escalation_stage,recipient_user_id,reason)
   values(r.filing_id,v_risk,v_stage,v_user,v_reason)
   on conflict(filing_id,risk_type,escalation_stage,recipient_user_id) do nothing returning id into v_notification;
   if v_notification is null then continue; end if;
   insert into public.notifications(user_id,title,message,type,reference_type,reference_id,is_read)
   values(v_user,case v_risk when 'overdue_filing' then 'Statutory filing overdue' when 'missing_acknowledgement' then 'Statutory filing closure evidence missing' when 'payment_reconciliation_variance' then 'Statutory payment variance unresolved' else 'Statutory payment reconciliation missing' end,v_reason||' Escalation stage: '||replace(v_stage,'_',' ')||'.','general','statutory_filing',r.filing_id)
   returning id into v_notification;
   update public.ft_statutory_risk_escalation_log set notification_id=v_notification where filing_id=r.filing_id and risk_type=v_risk and escalation_stage=v_stage and recipient_user_id=v_user;
   v_inserted:=v_inserted+1;
  end loop;
 end loop;
 return jsonb_build_object('success',true,'alerts_created',v_inserted,'processed_at',now());
end;$$;
revoke all on function public.ft_process_statutory_risk_escalations() from public,anon,authenticated;
grant execute on function public.ft_process_statutory_risk_escalations() to service_role;
select cron.schedule('frosttech-statutory-risk-escalations-daily','15 7 * * *',$job$select public.ft_process_statutory_risk_escalations();$job$);