-- TEST-ONLY schema compatibility fixture. Apply ONLY to frosttech-pr13-testing.
-- Adds the canonical combined department role while retaining legacy role keys.

begin;

alter table public.admin_role_permissions drop constraint if exists admin_role_permissions_role_check;
alter table public.admin_role_permissions add constraint admin_role_permissions_role_check
 check (role = any (array['super_admin','operations_admin','supplier_catalogue_admin','finance_admin','advertisers_admin','supplier_admin','catalogue_admin']::text[]));
alter table public.admin_accounts drop constraint if exists admin_accounts_role_check;
alter table public.admin_accounts add constraint admin_accounts_role_check
 check (role = any (array['super_admin','operations_admin','supplier_catalogue_admin','finance_admin','advertisers_admin','supplier_admin','catalogue_admin']::text[]));
alter table public.isolated_test_admin_grants drop constraint if exists isolated_test_admin_grants_role_check;
alter table public.isolated_test_admin_grants add constraint isolated_test_admin_grants_role_check
 check (role = any (array['finance_admin','supplier_catalogue_admin']::text[]));

-- Match production product-table grants: public roles may read approved
-- catalogue fields, but cannot access supplier_cost or write products directly.
revoke all on table public.products from anon, authenticated;
grant references, trigger on table public.products to anon, authenticated;
grant select (
 id, name, category, brand, model, description, sku, unit,
 selling_price, stock_quantity, min_stock_level, image_url,
 is_active, created_at, updated_at
) on table public.products to anon, authenticated;

insert into public.admin_role_permissions(role, permission)
values
 ('supplier_catalogue_admin','supplier_applications.manage'),
 ('supplier_catalogue_admin','supplier_applications.read'),
 ('supplier_catalogue_admin','supplier_applications.review'),
 ('supplier_catalogue_admin','supplier_verification.manage'),
 ('supplier_catalogue_admin','supplier_quotes.manage'),
 ('supplier_catalogue_admin','catalogue.manage'),
 ('supplier_catalogue_admin','products.manage'),
 ('supplier_catalogue_admin','selling_prices.manage'),
 ('supplier_catalogue_admin','stock.manage')
on conflict (role, permission) do nothing;

create or replace function public.admin_get_my_role()
returns text language plpgsql stable security definer set search_path to ''
as $function$
declare v_role text; v_profile_active boolean;
begin
 if auth.uid() is null then return null; end if;
 select p.is_active into v_profile_active from public.profiles p where p.id=auth.uid();
 if not found or v_profile_active is not true then return null; end if;
 select a.role into v_role from public.admin_accounts a where a.user_id=auth.uid() and a.is_active is true;
 if found then
  if v_role='super_admin' then if public.is_super_admin() then return 'super_admin'; end if; return null; end if;
  if v_role in ('operations_admin','supplier_catalogue_admin','supplier_admin','finance_admin','catalogue_admin','advertisers_admin') then return v_role; end if;
 end if;
 select g.role into v_role from public.isolated_test_admin_grants g
 where g.user_id=auth.uid() and g.is_active is true and g.revoked_at is null;
 if found then return v_role; end if;
 return null;
end;
$function$;

create or replace function public.supplier_admin_list_applications()
returns table(id uuid,user_id uuid,business_name text,contact_name text,phone text,email text,address text,city text,state text,is_verified boolean,is_active boolean,review_status text,review_reason text,reviewed_at timestamptz,created_at timestamptz)
language plpgsql security definer set search_path to ''
as $function$
begin
 if auth.uid() is null or not public.admin_has_permission('supplier_applications.manage') then
  raise exception 'Supplier application management access required.' using errcode='42501';
 end if;
 return query select s.id,s.user_id,s.business_name,s.contact_name,s.phone,s.email,s.address,s.city,s.state,s.is_verified,s.is_active,s.review_status,s.review_reason,s.reviewed_at,s.created_at from public.suppliers s order by s.created_at desc;
end;
$function$;
revoke all on function public.supplier_admin_list_applications() from public,anon;
grant execute on function public.supplier_admin_list_applications() to authenticated,service_role;

commit;
