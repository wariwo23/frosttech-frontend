-- FrostTech production security hotfix
-- Version: 20261126204404
-- Purpose: remove anon/authenticated visibility of products.supplier_cost
-- while preserving public catalogue reads of non-sensitive columns.
-- Also remove TRUNCATE privilege from client roles.
-- Applied to production Supabase project nftxptjpgidcsgtaltjn on 2026-11-26.

begin;

revoke select on table public.products from anon, authenticated;

grant select (
  id,
  supplier_id,
  name,
  category,
  brand,
  model,
  description,
  sku,
  unit,
  selling_price,
  stock_quantity,
  min_stock_level,
  image_url,
  is_active,
  created_at,
  updated_at
) on table public.products to anon, authenticated;

revoke truncate on table public.products from anon, authenticated;

commit;
