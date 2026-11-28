
create or replace function public.ft_save_statutory_payment_reconciliation_v2(
 p_filing_id uuid,p_filing_fee numeric,p_expense_id uuid,p_bank_transaction_id uuid,
 p_payment_reference text,p_receipt_document_id uuid,p_variance_note text,p_payment_execution_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 f public.ft_corporate_statutory_filings%rowtype;e public.ft_bookkeeping_expenses%rowtype;
 b public.ft_bookkeeping_bank_transactions%rowtype;x public.ft_treasury_payment_executions%rowtype;
 q public.ft_treasury_payment_requests%rowtype;v_fee numeric(14,2);v_expense numeric(14,2);
 v_bank numeric(14,2);v_status text;v_id uuid;v_event text;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if p_filing_fee is null or p_filing_fee<=0 then raise exception 'Enter the actual statutory fee'; end if;
 if p_payment_execution_id is null then raise exception 'A confirmed treasury payment execution is required for new reconciliations'; end if;
 select * into f from public.ft_corporate_statutory_filings where id=p_filing_id for update;
 if not found then raise exception 'Statutory filing not found'; end if;
 select * into e from public.ft_bookkeeping_expenses where id=p_expense_id;
 if not found then raise exception 'Expense register record not found'; end if;
 if e.status not in ('approved','paid','posted') then raise exception 'Expense must be approved or paid before reconciliation'; end if;
 v_fee:=p_filing_fee;v_expense:=e.amount;
 if p_bank_transaction_id is null then raise exception 'Select the corresponding bank debit'; end if;
 select * into b from public.ft_bookkeeping_bank_transactions where id=p_bank_transaction_id;
 if not found or b.debit<=0 then raise exception 'Selected bank transaction is not a valid debit'; end if;
 v_bank:=b.debit;
 select * into x from public.ft_treasury_payment_executions where id=p_payment_execution_id;
 if not found or x.execution_status<>'confirmed' then raise exception 'Only a confirmed payment execution can be reconciled'; end if;
 select * into q from public.ft_treasury_payment_requests where id=x.payment_request_id;
 if not found or q.statutory_filing_id is distinct from p_filing_id then raise exception 'Payment execution is not linked to the selected statutory filing'; end if;
 if nullif(trim(x.bank_reference),'') is null or trim(x.bank_reference) is distinct from trim(coalesce(b.reference,'')) then raise exception 'Bank transaction reference does not match confirmed execution'; end if;
 if x.executed_amount<>b.debit or x.executed_amount<>e.amount then raise exception 'Execution, expense and bank debit amounts must match'; end if;
 if x.evidence_document_id is null then raise exception 'Confirmed payment execution has no evidence document'; end if;
 if p_receipt_document_id is null or not exists(select 1 from public.ft_document_records where id=p_receipt_document_id and record_status='active') then raise exception 'An active Document Vault receipt is required'; end if;
 v_status:=case when v_fee=v_expense and v_expense=v_bank then 'matched' else 'variance' end;
 if v_status='variance' and length(btrim(coalesce(p_variance_note,'')))<5 then raise exception 'Explain the fee, expense or bank amount variance'; end if;
 update public.ft_corporate_statutory_filings set fee_amount=v_fee,payment_reference=nullif(btrim(p_payment_reference),''),payment_receipt_document_id=p_receipt_document_id,updated_at=now() where id=p_filing_id;
 insert into public.ft_statutory_payment_reconciliations(filing_id,expense_id,bank_transaction_id,payment_execution_id,filing_fee_amount,expense_amount,bank_debit_amount,reconciliation_status,variance_note,payment_reference,receipt_document_id,prepared_by,reconciled_by,reconciled_at,updated_at)
 values(p_filing_id,p_expense_id,p_bank_transaction_id,p_payment_execution_id,v_fee,v_expense,v_bank,v_status,nullif(btrim(p_variance_note),''),nullif(btrim(p_payment_reference),''),p_receipt_document_id,auth.uid(),case when v_status='matched' then auth.uid() end,case when v_status='matched' then now() end,now())
 on conflict(filing_id,expense_id) do update set bank_transaction_id=excluded.bank_transaction_id,payment_execution_id=excluded.payment_execution_id,filing_fee_amount=excluded.filing_fee_amount,expense_amount=excluded.expense_amount,bank_debit_amount=excluded.bank_debit_amount,reconciliation_status=excluded.reconciliation_status,variance_note=excluded.variance_note,payment_reference=excluded.payment_reference,receipt_document_id=excluded.receipt_document_id,reconciled_by=excluded.reconciled_by,reconciled_at=excluded.reconciled_at,updated_at=now() returning id into v_id;
 v_event:=case when v_status='matched' then 'reconciliation_matched' when v_status='variance' then 'reconciliation_variance' else 'receipt_linked' end;
 insert into public.ft_statutory_payment_reconciliation_events(reconciliation_id,event_type,actor_user_id,event_snapshot)
 values(v_id,v_event,auth.uid(),jsonb_build_object('filing_id',p_filing_id,'expense_id',p_expense_id,'bank_transaction_id',p_bank_transaction_id,'payment_execution_id',p_payment_execution_id,'filing_fee_amount',v_fee,'expense_amount',v_expense,'bank_debit_amount',v_bank,'status',v_status,'payment_reference',p_payment_reference,'receipt_document_id',p_receipt_document_id,'variance_note',p_variance_note));
 return jsonb_build_object('success',true,'reconciliation_id',v_id,'status',v_status,'payment_execution_id',p_payment_execution_id);
end $$;
revoke all on function public.ft_save_statutory_payment_reconciliation_v2(uuid,numeric,uuid,uuid,text,uuid,text,uuid) from public,anon;
grant execute on function public.ft_save_statutory_payment_reconciliation_v2(uuid,numeric,uuid,uuid,text,uuid,text,uuid) to authenticated;
