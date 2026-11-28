
alter table public.ft_corporate_statutory_filings
 add constraint ft_statutory_filing_completion_closed_evidence_ck
 check (
  completion_closed_at is null
  or (
   status = 'accepted'
   and filed_date is not null
   and length(btrim(coalesce(filing_reference,''))) >= 3
   and length(btrim(coalesce(payment_reference,''))) >= 3
   and length(btrim(coalesce(acknowledgement_reference,''))) >= 3
   and acknowledgement_document_id is not null
   and payment_receipt_document_id is not null
   and completion_closed_by is not null
  )
 );
