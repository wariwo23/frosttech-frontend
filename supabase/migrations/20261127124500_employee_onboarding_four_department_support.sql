-- Four-department employee onboarding compatibility.
-- Preserve legacy department values for existing records, while accepting all
-- four canonical departments for new employee registrations.

do $migration$
declare
  v_oid oid;
  v_definition text;
  v_old text;
  v_new text;
begin
  v_oid := to_regprocedure('public.admin_create_frosttech_employee(text,text,text,text)')::oid;
  if v_oid is null then
    raise exception 'Required employee creation function is missing';
  end if;

  v_definition := pg_get_functiondef(v_oid);

  v_old := $old$IF v_department IS NULL OR v_department NOT IN (
    'operations',
    'supplier_management',
    'finance',
    'catalogue'
  ) THEN$old$;

  v_new := $new$IF v_department IS NULL OR v_department NOT IN (
    'operations',
    'supplier_management',
    'finance',
    'catalogue',
    'supplier_catalogue',
    'advertisers_communications'
  ) THEN$new$;

  if position(v_old in v_definition) > 0 then
    v_definition := replace(v_definition, v_old, v_new);
  elsif position(v_new in v_definition) = 0 then
    raise exception 'Unexpected department validation block; migration stopped safely';
  end if;

  execute v_definition;
end
$migration$;
