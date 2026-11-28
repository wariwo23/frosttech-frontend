-- Statutory filing payment authorisation linked to existing treasury controls.
alter table public.ft_treasury_payment_requests
  add column if not exists statutory_filing_id uuid
  references public.ft_corporate_statutory_filings(id) on delete restrict;
create unique index if not exists ft_treasury_payment_requests_statutory_filing_uidx
  on public.ft_treasury_payment_requests(statutory_filing_id)
  where statutory_filing_id is not null;

create or replace function public.ft_list_statutory_filing_payment_choices()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_role text;
begin
 v_role:=public.admin_get_my_role();
 if v_role not in ('finance_admin','super_admin') then raise exception 'Not authorised'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'filing_type',f.filing_type,'authority_name',f.authority_name,'due_date',f.due_date,'fee_amount',f.fee_amount,'status',f.status,'filing_reference',f.filing_reference) order by f.due_date nulls last,f.created_at desc)
 from public.ft_corporate_statutory_filings f
 where f.status not in ('accepted','not_applicable')
 and not exists(select 1 from public.ft_treasury_payment_requests p where p.statutory_filing_id=f.id and p.request_status not in ('rejected','cancelled'))),'[]'::jsonb);
end $$;

create or replace function public.ft_list_statutory_payment_requests()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_role text;
begin
 v_role:=public.admin_get_my_role();
 if v_role not in ('finance_admin','super_admin') then raise exception 'Not authorised'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
 'id',p.id,'payment_request_ref',p.payment_request_ref,'statutory_filing_id',p.statutory_filing_id,
 'filing_type',f.filing_type,'authority_name',f.authority_name,'payee_name',p.payee_name,
 'payee_bank_name',p.payee_bank_name,'payee_account_masked',p.payee_account_masked,
 'amount',p.amount,'currency_code',p.currency_code,'payment_purpose',p.payment_purpose,
 'due_date',p.due_date,'request_status',p.request_status,'requested_by',p.requested_by,
 'submitted_at',p.submitted_at,'created_at',p.created_at,'approval_decision',a.approval_decision,
 'approval_note',a.decision_notes,'approver_user_id',a.approver_user_id,'decided_at',a.decided_at,
 'executions',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'executed_amount',e.executed_amount,'execution_date',e.execution_date,'payment_channel',e.payment_channel,'bank_reference',e.bank_reference,'execution_status',e.execution_status,'evidence_document_id',e.evidence_document_id,'recorded_by',e.recorded_by,'created_at',e.created_at) order by e.created_at)
 from public.ft_treasury_payment_executions e where e.payment_request_id=p.id),'[]'::jsonb)
 ) order by p.created_at desc)
 from public.ft_treasury_payment_requests p join public.ft_corporate_statutory_filings f on f.id=p.statutory_filing_id
 left join public.ft_treasury_payment_approvals a on a.payment_request_id=p.id and a.approval_stage=1),'[]'::jsonb);
end $$;

create or replace function public.ft_prepare_statutory_payment_request(
 p_filing_id uuid,p_amount numeric,p_payee_name text,p_payee_bank_name text,
 p_payee_account_masked text,p_due_date date,p_supporting_document_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid:=auth.uid(); v_filing public.ft_corporate_statutory_filings%rowtype; v_id uuid; v_ref text;
begin
 if v_user is null or public.admin_get_my_role()<>'finance_admin' then raise exception 'Only Finance Administrator may prepare statutory payment requests'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Positive amount required'; end if;
 if nullif(trim(p_payee_name),'') is null then raise exception 'Payee name required'; end if;
 select * into v_filing from public.ft_corporate_statutory_filings where id=p_filing_id for update;
 if not found then raise exception 'Filing not found'; end if;
 if v_filing.status in ('accepted','not_applicable') then raise exception 'Filing does not require payment'; end if;
 if v_filing.fee_amount is null or v_filing.fee_amount<>p_amount then raise exception 'Amount must match the filing fee recorded in the statutory register'; end if;
 if exists(select 1 from public.ft_treasury_payment_requests p where p.statutory_filing_id=p_filing_id and p.request_status not in ('rejected','cancelled')) then raise exception 'An active request already exists'; end if;
 v_ref:='FT-STAT-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.ft_treasury_payment_requests(payment_request_ref,payee_name,payee_bank_name,payee_account_masked,amount,currency_code,payment_purpose,due_date,supporting_document_id,request_status,requested_by,submitted_at,statutory_filing_id)
 values(v_ref,trim(p_payee_name),nullif(trim(p_payee_bank_name),''),nullif(trim(p_payee_account_masked),''),p_amount,'NGN','Statutory filing fee: '||v_filing.filing_type||' — '||v_filing.authority_name,coalesce(p_due_date,v_filing.due_date),p_supporting_document_id,'submitted',v_user,now(),p_filing_id) returning id into v_id;
 insert into public.ft_treasury_payment_approvals(payment_request_id,approval_stage,approval_decision) values(v_id,1,'pending');
 insert into public.ft_treasury_events(event_type,entity_type,entity_id,event_details,actor_user_id) values('statutory_payment_submitted','payment_request',v_id,jsonb_build_object('filing_id',p_filing_id,'amount',p_amount,'reference',v_ref),v_user);
 return v_id;
end $$;

create or replace function public.ft_decide_statutory_payment_request(p_request_id uuid,p_decision text,p_note text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_user uuid:=auth.uid(); v_request public.ft_treasury_payment_requests%rowtype;
begin
 if public.admin_get_my_role()<>'super_admin' then raise exception 'Only Super Administrator may authorise statutory payments'; end if;
 if p_decision not in ('approved','rejected') then raise exception 'Invalid decision'; end if;
 if nullif(trim(p_note),'') is null then raise exception 'Decision note required'; end if;
 select * into v_request from public.ft_treasury_payment_requests where id=p_request_id and statutory_filing_id is not null for update;
 if not found then raise exception 'Payment request not found'; end if;
 if v_request.requested_by=v_user then raise exception 'Preparer cannot approve own request'; end if;
 if v_request.request_status not in ('submitted','under_review') then raise exception 'Request is not awaiting authorisation'; end if;
 update public.ft_treasury_payment_approvals set approver_user_id=v_user,approval_decision=p_decision,decision_notes=trim(p_note),decided_at=now()
 where payment_request_id=p_request_id and approval_stage=1 and approval_decision='pending';
 if not found then raise exception 'Pending approval stage not found'; end if;
 update public.ft_treasury_payment_requests set request_status=p_decision,updated_at=now() where id=p_request_id;
 insert into public.ft_treasury_events(event_type,entity_type,entity_id,event_details,actor_user_id) values('statutory_payment_'||p_decision,'payment_request',p_request_id,jsonb_build_object('decision',p_decision,'note',trim(p_note)),v_user);
 return true;
end $$;

create or replace function public.ft_record_statutory_payment_execution(
 p_request_id uuid,p_executed_amount numeric,p_execution_date date,p_payment_channel text,
 p_bank_reference text,p_execution_status text,p_evidence_document_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid:=auth.uid(); v_request public.ft_treasury_payment_requests%rowtype; v_id uuid; v_total numeric;
begin
 if public.admin_get_my_role()<>'finance_admin' then raise exception 'Only Finance Administrator may record payment execution'; end if;
 if p_executed_amount is null or p_executed_amount<=0 then raise exception 'Positive execution amount required'; end if;
 if p_execution_date is null or nullif(trim(p_payment_channel),'') is null then raise exception 'Execution date and payment channel required'; end if;
 if p_execution_status not in ('submitted_to_bank','confirmed') then raise exception 'Invalid execution status'; end if;
 if p_execution_status='confirmed' and (nullif(trim(p_bank_reference),'') is null or p_evidence_document_id is null) then raise exception 'Confirmed execution requires bank reference and evidence document'; end if;
 select * into v_request from public.ft_treasury_payment_requests where id=p_request_id and statutory_filing_id is not null for update;
 if not found then raise exception 'Payment request not found'; end if;
 if v_request.request_status not in ('approved','scheduled') then raise exception 'Payment must be authorised before execution'; end if;
 select coalesce(sum(executed_amount),0) into v_total from public.ft_treasury_payment_executions where payment_request_id=p_request_id and execution_status='confirmed';
 if p_execution_status='confirmed' and v_total+p_executed_amount>v_request.amount then raise exception 'Confirmed execution exceeds authorised amount'; end if;
 insert into public.ft_treasury_payment_executions(payment_request_id,execution_reference,executed_amount,execution_date,payment_channel,bank_reference,execution_status,evidence_document_id,recorded_by)
 values(p_request_id,'FT-EXEC-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),p_executed_amount,p_execution_date,trim(p_payment_channel),nullif(trim(p_bank_reference),''),p_execution_status,p_evidence_document_id,v_user) returning id into v_id;
 if p_execution_status='confirmed' and v_total+p_executed_amount=v_request.amount then update public.ft_treasury_payment_requests set request_status='paid',updated_at=now() where id=p_request_id; end if;
 insert into public.ft_treasury_events(event_type,entity_type,entity_id,event_details,actor_user_id) values('statutory_payment_execution_recorded','payment_execution',v_id,jsonb_build_object('request_id',p_request_id,'amount',p_executed_amount,'status',p_execution_status,'bank_reference',p_bank_reference),v_user);
 return v_id;
end $$;

revoke all on function public.ft_list_statutory_filing_payment_choices() from public,anon;
revoke all on function public.ft_list_statutory_payment_requests() from public,anon;
revoke all on function public.ft_prepare_statutory_payment_request(uuid,numeric,text,text,text,date,uuid) from public,anon;
revoke all on function public.ft_decide_statutory_payment_request(uuid,text,text) from public,anon;
revoke all on function public.ft_record_statutory_payment_execution(uuid,numeric,date,text,text,text,uuid) from public,anon;
grant execute on function public.ft_list_statutory_filing_payment_choices() to authenticated;
grant execute on function public.ft_list_statutory_payment_requests() to authenticated;
grant execute on function public.ft_prepare_statutory_payment_request(uuid,numeric,text,text,text,date,uuid) to authenticated;
grant execute on function public.ft_decide_statutory_payment_request(uuid,text,text) to authenticated;
grant execute on function public.ft_record_statutory_payment_execution(uuid,numeric,date,text,text,text,uuid) to authenticated;
