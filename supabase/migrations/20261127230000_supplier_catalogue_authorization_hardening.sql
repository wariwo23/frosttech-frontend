-- Supplier & Catalogue authorization hardening
-- Production project: nftxptjpgidcsgtaltjn
-- Removes broad legacy administrator table policies. Supplier reads are
-- permission-gated; supplier decisions remain RPC-only.

begin;

drop policy if exists suppliers_admin_delete on public.suppliers;
drop policy if exists suppliers_admin_insert on public.suppliers;
drop policy if exists suppliers_admin_update on public.suppliers;
drop policy if exists suppliers_read_own_or_admin on public.suppliers;

create policy suppliers_read_own_or_authorized
on public.suppliers
for select
to authenticated
using (
  user_id = (select auth.uid())
  or public.admin_has_permission('supplier_applications.read')
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
declare
  v_supplier_id uuid;
begin
  if auth.uid() is null
     or not public.admin_has_permission('supplier_verification.manage') then
    raise exception 'Supplier verification access required';
  end if;

  if target_supplier_id is null then
    raise exception 'A supplier record is required';
  end if;

  if new_status is null or new_status not in (
    'pending',
    'in_review',
    'more_info',
    'approved',
    'rejected',
    'suspended'
  ) then
    raise exception 'Invalid supplier review status';
  end if;

  if new_status in ('rejected', 'suspended')
     and nullif(pg_catalog.btrim(reason), '') is null then
    raise exception 'A reason is required for rejection or suspension';
  end if;

  -- Serialize concurrent decisions and confirm that the supplier exists.
  select s.id
    into v_supplier_id
  from public.suppliers s
  where s.id = target_supplier_id
  for update;

  if not found then
    raise exception 'Supplier not found';
  end if;

  -- Only approved suppliers are verified and active. Every other review
  -- state remains inactive until an explicit approval is recorded.
  update public.suppliers
  set review_status = new_status,
      is_verified = (new_status = 'approved'),
      is_active = (new_status = 'approved'),
      review_reason = nullif(pg_catalog.btrim(reason), ''),
      reviewed_by = auth.uid(),
      reviewed_at = pg_catalog.now(),
      updated_at = pg_catalog.now()
  where id = target_supplier_id;

  insert into public.admin_activity_log (
    actor_user_id, action, target_user_id, details
  )
  select
    auth.uid(),
    'supplier_review_' || new_status,
    s.user_id,
    pg_catalog.jsonb_build_object(
      'supplier_id', target_supplier_id,
      'status', new_status,
      'reason', nullif(pg_catalog.btrim(reason), '')
    )
  from public.suppliers s
  where s.id = target_supplier_id;

  return true;
end;
$function$;

comment on function public.admin_review_supplier(uuid,text,text) is
'Permission-gated supplier review. Serializes decisions and activates only approved suppliers.';

commit;
