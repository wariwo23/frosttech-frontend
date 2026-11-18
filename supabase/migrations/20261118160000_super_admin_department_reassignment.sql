-- Super Admin-only employee department reassignment.
-- This migration is review-only until separately approved and executed.
-- It preserves existing employee records and any current administrator activation state.

create or replace function public.admin_reassign_frosttech_employee_department(
  p_employee_id uuid,
  p_department text
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_employee record;
  v_new_role text;
  v_existing_role text;
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Super Administrator access required';
  end if;

  if p_employee_id is null then
    raise exception 'Employee record is required';
  end if;

  if p_department is null or p_department not in (
    'operations',
    'supplier_management',
    'finance',
    'catalogue'
  ) then
    raise exception 'Select a valid FrostTech department';
  end if;

  select
    e.id,
    e.auth_user_id,
    e.full_name,
    e.email,
    e.department,
    e.employment_status
  into v_employee
  from public.frosttech_employees e
  where e.id = p_employee_id
  for update;

  if not found then
    raise exception 'Employee record not found';
  end if;

  if v_employee.employment_status = 'terminated' then
    raise exception 'A terminated employee cannot be reassigned';
  end if;

  v_new_role := case p_department
    when 'operations' then 'operations_admin'
    when 'supplier_management' then 'supplier_admin'
    when 'finance' then 'finance_admin'
    when 'catalogue' then 'catalogue_admin'
    else null
  end;

  if v_employee.auth_user_id is not null then
    select a.role
    into v_existing_role
    from public.admin_accounts a
    where a.user_id = v_employee.auth_user_id
    for update;

    if found and v_existing_role = 'super_admin' then
      raise exception 'The permanent Super Administrator account cannot be reassigned';
    end if;

    if found and v_existing_role not in (
      'operations_admin',
      'supplier_admin',
      'finance_admin',
      'catalogue_admin'
    ) then
      raise exception 'This employee has an unexpected administrator role; resolve it before changing departments';
    end if;
  end if;

  update public.frosttech_employees
  set department = p_department,
      updated_at = now()
  where id = p_employee_id;

  if v_employee.auth_user_id is not null
     and v_existing_role in (
       'operations_admin',
       'supplier_admin',
       'finance_admin',
       'catalogue_admin'
     ) then
    update public.admin_accounts
    set role = v_new_role,
        appointed_by = auth.uid(),
        appointed_at = now(),
        updated_at = now()
    where user_id = v_employee.auth_user_id
      and role <> 'super_admin';
  end if;

  insert into public.admin_activity_log (
    actor_user_id,
    action,
    target_user_id,
    details
  )
  values (
    auth.uid(),
    'frosttech_employee_department_reassigned',
    v_employee.auth_user_id,
    jsonb_build_object(
      'employee_id', p_employee_id,
      'employee_email', v_employee.email,
      'previous_department', v_employee.department,
      'new_department', p_department,
      'previous_administrator_role', v_existing_role,
      'new_administrator_role',
        case
          when v_existing_role in (
            'operations_admin',
            'supplier_admin',
            'finance_admin',
            'catalogue_admin'
          ) then v_new_role
          else null
        end
    )
  );

  return true;
end;
$function$;

revoke all on function public.admin_reassign_frosttech_employee_department(uuid, text)
  from public, anon;
grant execute on function public.admin_reassign_frosttech_employee_department(uuid, text)
  to authenticated;

comment on function public.admin_reassign_frosttech_employee_department(uuid, text)
  is 'Super Admin-only employee department reassignment. Synchronizes an existing departmental administrator role and records an audit event.';
