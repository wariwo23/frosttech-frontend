-- Rollback for 20261127230000_supplier_catalogue_authorization_hardening.sql
-- Restores the prior supplier policies and prior review function.
-- WARNING: this reintroduces legacy is_admin()-based table access.

begin;

drop policy if exists suppliers_read_own_or_authorized on public.suppliers;

create policy suppliers_admin_delete
on public.suppliers for delete to authenticated
using (public.is_admin());

create policy suppliers_admin_insert
on public.suppliers for insert to authenticated
with check (public.is_admin());

create policy suppliers_admin_update
on public.suppliers for update to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy suppliers_read_own_or_admin
on public.suppliers for select to authenticated
using (
  user_id = (select auth.uid())
  or public.is_admin()
);

create or replace function public.admin_review_supplier(
  target_supplier_id uuid,
  new_status text,
  reason text default null
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if auth.uid() is null
     or not public.admin_has_permission('supplier_verification.manage') then
    raise exception 'Supplier verification access required';
  end if;

  if new_status is null or new_status not in (
    'pending','in_review','more_info','approved','rejected','suspended'
  ) then
    raise exception 'Invalid supplier review status';
  end if;

  if new_status in ('rejected','suspended')
     and nullif(pg_catalog.btrim(reason),'') is null then
    raise exception 'A reason is required for rejection or suspension';
  end if;

  update public.suppliers
  set review_status = new_status,
      is_verified = (new_status = 'approved'),
      is_active = (new_status <> 'suspended'),
      review_reason = nullif(pg_catalog.btrim(reason),''),
      reviewed_by = auth.uid(),
      reviewed_at = pg_catalog.now(),
      updated_at = pg_catalog.now()
  where id = target_supplier_id;

  if not found then
    raise exception 'Supplier not found';
  end if;

  insert into public.admin_activity_log (
    actor_user_id, action, target_user_id, details
  )
  values (
    auth.uid(),
    'supplier_review_' || new_status,
    null,
    pg_catalog.jsonb_build_object(
      'supplier_id', target_supplier_id,
      'status', new_status,
      'reason', nullif(pg_catalog.btrim(reason),'')
    )
  );

  return true;
end;
$function$;

commit;
