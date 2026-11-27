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


-- Catalogue RPCs synchronized with production. These functions deliberately
-- return no supplier_cost field and enforce department-specific permissions.
create or replace function public.catalogue_create_product(
 p_name text,p_category text default null,p_brand text default null,p_model text default null,
 p_description text default null,p_sku text default null,p_unit text default 'piece',
 p_image_url text default null,p_stock_quantity integer default 0,p_min_stock_level integer default 0
) returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_id uuid;
begin
 if auth.uid() is null or not public.admin_has_permission('products.manage') then
  raise exception 'Catalogue product-management permission required';
 end if;
 if nullif(pg_catalog.btrim(p_name),'') is null then raise exception 'Product name is required'; end if;
 if p_stock_quantity is null or p_stock_quantity<0 or p_min_stock_level is null or p_min_stock_level<0 then
  raise exception 'Stock quantities must be non-negative';
 end if;
 insert into public.products(name,category,brand,model,description,sku,unit,image_url,supplier_id,supplier_cost,selling_price,stock_quantity,min_stock_level,is_active)
 values(pg_catalog.btrim(p_name),nullif(pg_catalog.btrim(p_category),''),nullif(pg_catalog.btrim(p_brand),''),nullif(pg_catalog.btrim(p_model),''),nullif(pg_catalog.btrim(p_description),''),nullif(pg_catalog.btrim(p_sku),''),coalesce(nullif(pg_catalog.btrim(p_unit),''),'piece'),nullif(pg_catalog.btrim(p_image_url),''),null,null,null,p_stock_quantity,p_min_stock_level,false)
 returning id into v_id;
 insert into public.admin_activity_log(actor_user_id,action,details)
 values(auth.uid(),'catalogue_product_created',pg_catalog.jsonb_build_object('product_id',v_id,'name',pg_catalog.btrim(p_name),'created_inactive',true));
 return v_id;
end;
$function$;

create or replace function public.catalogue_list_products()
returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v_result jsonb;
begin
 if auth.uid() is null or not public.admin_has_permission('products.manage') then
  raise exception 'Catalogue administrator access required';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'name',p.name,'category',p.category,'brand',p.brand,'model',p.model,
  'description',p.description,'sku',p.sku,'unit',p.unit,'selling_price',p.selling_price,
  'stock_quantity',p.stock_quantity,'min_stock_level',p.min_stock_level,
  'image_url',p.image_url,'is_active',p.is_active,'created_at',p.created_at,'updated_at',p.updated_at
 ) order by p.created_at desc),'[]'::jsonb)
 into v_result from public.products p;
 return v_result;
end;
$function$;

create or replace function public.catalogue_set_product_active(p_product_id uuid,p_is_active boolean)
returns boolean language plpgsql security definer set search_path to ''
as $function$
declare v_old_active boolean;
begin
 if auth.uid() is null or not public.admin_has_permission('products.manage') then raise exception 'Catalogue product-management permission required'; end if;
 if p_product_id is null or p_is_active is null then raise exception 'A product and active status are required'; end if;
 select p.is_active into v_old_active from public.products p where p.id=p_product_id for update;
 if not found then raise exception 'Product not found'; end if;
 update public.products set is_active=p_is_active,updated_at=pg_catalog.now() where id=p_product_id;
 insert into public.admin_activity_log(actor_user_id,action,details)
 values(auth.uid(),'catalogue_product_status_updated',pg_catalog.jsonb_build_object('product_id',p_product_id,'previous_is_active',v_old_active,'new_is_active',p_is_active));
 return true;
end;
$function$;

create or replace function public.catalogue_update_product_details(
 p_product_id uuid,p_name text,p_category text,p_brand text,p_model text,p_description text,p_sku text,p_unit text,p_image_url text
) returns boolean language plpgsql security definer set search_path to ''
as $function$
declare v_old_name text;
begin
 if auth.uid() is null or not public.admin_has_permission('products.manage') then raise exception 'Catalogue product-management permission required'; end if;
 if p_product_id is null or nullif(pg_catalog.btrim(p_name),'') is null then raise exception 'A product and product name are required'; end if;
 select p.name into v_old_name from public.products p where p.id=p_product_id for update;
 if not found then raise exception 'Product not found'; end if;
 update public.products set name=pg_catalog.btrim(p_name),category=nullif(pg_catalog.btrim(p_category),''),brand=nullif(pg_catalog.btrim(p_brand),''),model=nullif(pg_catalog.btrim(p_model),''),description=nullif(pg_catalog.btrim(p_description),''),sku=nullif(pg_catalog.btrim(p_sku),''),unit=nullif(pg_catalog.btrim(p_unit),''),image_url=nullif(pg_catalog.btrim(p_image_url),''),updated_at=pg_catalog.now() where id=p_product_id;
 insert into public.admin_activity_log(actor_user_id,action,details)
 values(auth.uid(),'catalogue_product_details_updated',pg_catalog.jsonb_build_object('product_id',p_product_id,'previous_name',v_old_name,'new_name',pg_catalog.btrim(p_name)));
 return true;
end;
$function$;

create or replace function public.catalogue_update_selling_price(p_product_id uuid,p_selling_price numeric)
returns boolean language plpgsql security definer set search_path to ''
as $function$
declare v_old_price numeric;
begin
 if auth.uid() is null or not public.admin_has_permission('selling_prices.manage') then raise exception 'Selling-price management permission required'; end if;
 if p_product_id is null or p_selling_price is null or p_selling_price<0 then raise exception 'A valid product and non-negative selling price are required'; end if;
 select p.selling_price into v_old_price from public.products p where p.id=p_product_id for update;
 if not found then raise exception 'Product not found'; end if;
 update public.products set selling_price=p_selling_price,updated_at=pg_catalog.now() where id=p_product_id;
 insert into public.admin_activity_log(actor_user_id,action,details)
 values(auth.uid(),'catalogue_selling_price_updated',pg_catalog.jsonb_build_object('product_id',p_product_id,'previous_selling_price',v_old_price,'new_selling_price',p_selling_price));
 return true;
end;
$function$;

create or replace function public.catalogue_update_stock(p_product_id uuid,p_stock_quantity integer,p_min_stock_level integer)
returns boolean language plpgsql security definer set search_path to ''
as $function$
declare v_old_stock integer; v_old_min integer;
begin
 if auth.uid() is null or not public.admin_has_permission('stock.manage') then raise exception 'Stock-management permission required'; end if;
 if p_product_id is null or p_stock_quantity is null or p_min_stock_level is null or p_stock_quantity<0 or p_min_stock_level<0 then raise exception 'Valid non-negative stock values are required'; end if;
 select p.stock_quantity,p.min_stock_level into v_old_stock,v_old_min from public.products p where p.id=p_product_id for update;
 if not found then raise exception 'Product not found'; end if;
 update public.products set stock_quantity=p_stock_quantity,min_stock_level=p_min_stock_level,updated_at=pg_catalog.now() where id=p_product_id;
 insert into public.admin_activity_log(actor_user_id,action,details)
 values(auth.uid(),'catalogue_stock_updated',pg_catalog.jsonb_build_object('product_id',p_product_id,'previous_stock_quantity',v_old_stock,'new_stock_quantity',p_stock_quantity,'previous_min_stock_level',v_old_min,'new_min_stock_level',p_min_stock_level));
 return true;
end;
$function$;

revoke all on function public.catalogue_create_product(text,text,text,text,text,text,text,text,integer,integer) from public,anon;
revoke all on function public.catalogue_list_products() from public,anon;
revoke all on function public.catalogue_set_product_active(uuid,boolean) from public,anon;
revoke all on function public.catalogue_update_product_details(uuid,text,text,text,text,text,text,text,text) from public,anon;
revoke all on function public.catalogue_update_selling_price(uuid,numeric) from public,anon;
revoke all on function public.catalogue_update_stock(uuid,integer,integer) from public,anon;
grant execute on function public.catalogue_create_product(text,text,text,text,text,text,text,text,integer,integer) to authenticated,service_role;
grant execute on function public.catalogue_list_products() to authenticated,service_role;
grant execute on function public.catalogue_set_product_active(uuid,boolean) to authenticated,service_role;
grant execute on function public.catalogue_update_product_details(uuid,text,text,text,text,text,text,text,text) to authenticated,service_role;
grant execute on function public.catalogue_update_selling_price(uuid,numeric) to authenticated,service_role;
grant execute on function public.catalogue_update_stock(uuid,integer,integer) to authenticated,service_role;

commit;
