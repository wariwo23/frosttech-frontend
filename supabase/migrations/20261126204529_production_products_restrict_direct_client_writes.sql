-- Applied to production Supabase project nftxptjpgidcsgtaltjn on 2026-11-26.
-- Admin product writes now use permission-checked catalogue RPCs.
begin;
revoke insert, update, delete on table public.products from anon, authenticated;
commit;
