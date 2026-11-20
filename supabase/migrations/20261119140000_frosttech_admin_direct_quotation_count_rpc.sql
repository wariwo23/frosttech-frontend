-- FrostTech: restricted count for independent direct quotations.
-- Additive migration. Does not change existing table policies or workflows.

begin;

create or replace function public.frosttech_admin_count_direct_quotations()
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    v_actor uuid := auth.uid();
begin
    if v_actor is null then
        raise exception 'Authentication required';
    end if;

    if not exists (
        select 1
        from public.admin_accounts a
        join public.profiles p
          on p.id = a.user_id
        where a.user_id = v_actor
          and a.is_active is true
          and p.is_active is true
          and a.role in ('super_admin', 'operations_admin')
    ) then
        raise exception 'Active administrator access required';
    end if;

    return (
        select count(*)::bigint
        from public.frosttech_direct_quotations
    );
end;
$function$;

revoke all on function
    public.frosttech_admin_count_direct_quotations()
    from public;

revoke all on function
    public.frosttech_admin_count_direct_quotations()
    from anon;

revoke all on function
    public.frosttech_admin_count_direct_quotations()
    from authenticated;

grant execute on function
    public.frosttech_admin_count_direct_quotations()
    to authenticated;

comment on function
    public.frosttech_admin_count_direct_quotations()
    is 'Returns only the total independent quotation count to active FrostTech Super Administrators and Operations Administrators.';

commit;
