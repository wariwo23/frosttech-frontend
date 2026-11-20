-- Restrict the receipt-delivery trigger function to trigger execution only.
-- Keep its trigger behavior while using a fixed, empty search_path.
begin;

create or replace function public.frosttech_create_receipt_delivery_record()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
begin
  insert into public.payment_receipt_delivery(receipt_id,document_status,email_status)
  values (new.id,'pending','pending')
  on conflict (receipt_id) do nothing;
  return new;
end;
$function$;

revoke all on function public.frosttech_create_receipt_delivery_record()
    from public,anon,authenticated;

commit;
