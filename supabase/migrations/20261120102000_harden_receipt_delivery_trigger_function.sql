-- Restrict the receipt-delivery trigger function to trigger execution only.
-- The trigger continues to run on receipt creation; API roles cannot invoke it directly.
begin;

revoke all on function public.frosttech_create_receipt_delivery_record()
    from public,anon,authenticated;

commit;
