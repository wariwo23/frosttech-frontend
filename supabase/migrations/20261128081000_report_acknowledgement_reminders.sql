-- FrostTech report acknowledgement reminders and escalation
-- Additive production migration. Creates an immutable audit trail and a daily
-- in-app reminder/escalation processor. No existing delivery or acknowledgement
-- records are rewritten. Email is intentionally not sent by this scheduler.

create table if not exists public.ft_report_acknowledgement_reminders (
 id uuid primary key default gen_random_uuid(),
 report_type text not null check(report_type in ('management_report','annual_exception_review')),
 delivery_id uuid not null,
 action text not null check(action in ('reminder_7d','escalation_14d')),
 recipient_user_id uuid not null references auth.users(id),
 recipient_email text not null,
 due_at timestamptz not null,
 notification_id uuid references public.notifications(id),
 created_at timestamptz not null default now(),
 unique(report_type,delivery_id,action)
);
alter table public.ft_report_acknowledgement_reminders enable row level security;
revoke all on public.ft_report_acknowledgement_reminders from anon,authenticated;
grant select on public.ft_report_acknowledgement_reminders to authenticated;
drop policy if exists ft_report_acknowledgement_reminders_super_read on public.ft_report_acknowledgement_reminders;
create policy ft_report_acknowledgement_reminders_super_read on public.ft_report_acknowledgement_reminders for select to authenticated using (public.is_super_admin());

create or replace function public.ft_prevent_report_acknowledgement_reminder_mutation()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'Report acknowledgement reminder history is immutable'; end; $$;
revoke all on function public.ft_prevent_report_acknowledgement_reminder_mutation() from public,anon,authenticated;
drop trigger if exists ft_report_ack_reminder_immutable on public.ft_report_acknowledgement_reminders;
create trigger ft_report_ack_reminder_immutable before update or delete on public.ft_report_acknowledgement_reminders for each row execute function public.ft_prevent_report_acknowledgement_reminder_mutation();

create or replace function public.ft_process_report_acknowledgement_reminders()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_super uuid;
 v_created integer:=0;
 v_row record;
 v_action text;
 v_target uuid;
 v_title text;
 v_message text;
 v_notification uuid;
 v_lock bigint;
begin
 select id into v_super from auth.users where lower(email)='unajite@yahoo.com' limit 1;
 if v_super is null then raise exception 'Configured Super Administrator account was not found'; end if;
 for v_row in
  with deliveries as (
   select 'management_report'::text report_type,d.id delivery_id,d.recipient_user_id,d.recipient_email,d.delivered_at,
          (a.delivery_attempt_id is not null) acknowledged
   from public.ft_management_report_delivery_attempts d
   left join public.ft_management_report_acknowledgements a on a.delivery_attempt_id=d.id
   where d.delivery_status='sent' and d.delivered_at is not null
   union all
   select 'annual_exception_review',d.id,d.recipient_user_id,d.recipient_email,d.delivered_at,
          (a.delivery_id is not null)
   from public.ft_exception_annual_review_deliveries d
   left join public.ft_exception_annual_review_acknowledgements a on a.delivery_id=d.id
   where d.delivery_status='sent' and d.delivered_at is not null
  )
  select * from deliveries where not acknowledged and now() >= delivered_at + interval '7 days'
 loop
  foreach v_action in array array['reminder_7d','escalation_14d'] loop
   if (v_action='reminder_7d' and now() < v_row.delivered_at + interval '7 days')
      or (v_action='escalation_14d' and now() < v_row.delivered_at + interval '14 days') then continue; end if;
   v_lock:=hashtextextended(v_row.report_type||':'||v_row.delivery_id::text||':'||v_action,0);
   perform pg_advisory_xact_lock(v_lock);
   if exists(select 1 from public.ft_report_acknowledgement_reminders where report_type=v_row.report_type and delivery_id=v_row.delivery_id and action=v_action) then continue; end if;
   v_target:=case when v_action='reminder_7d' then v_row.recipient_user_id else v_super end;
   v_title:=case when v_action='reminder_7d' then 'Reminder: acknowledge FrostTech management report' else 'Escalation: report acknowledgement overdue' end;
   v_message:=case when v_action='reminder_7d'
    then 'A FrostTech approved report was delivered to your account at '||v_row.delivered_at::text||'. Please sign in to the management report recipient workspace and acknowledge receipt. This confirms receipt only, not approval.'
    else 'The report delivered to '||v_row.recipient_email||' on '||v_row.delivered_at::text||' remains unacknowledged after 14 days. Report type: '||v_row.report_type||'; delivery reference: '||v_row.delivery_id::text||'. Please follow up with the recipient.'
   end;
   insert into public.notifications(user_id,title,message,type,reference_type,reference_id)
   values(v_target,v_title,v_message,'report_acknowledgement',v_row.report_type,v_row.delivery_id)
   returning id into v_notification;
   insert into public.ft_report_acknowledgement_reminders(report_type,delivery_id,action,recipient_user_id,recipient_email,due_at,notification_id)
   values(v_row.report_type,v_row.delivery_id,v_action,v_target,
          case when v_action='reminder_7d' then v_row.recipient_email else 'unajite@yahoo.com' end,
          v_row.delivered_at + case when v_action='reminder_7d' then interval '7 days' else interval '14 days' end,
          v_notification);
   v_created:=v_created+1;
   v_notification:=null;
  end loop;
 end loop;
 return jsonb_build_object('success',true,'notifications_created',v_created);
end; $$;
revoke all on function public.ft_process_report_acknowledgement_reminders() from public,anon,authenticated;

select cron.schedule('frosttech-report-acknowledgement-reminders-daily','0 7 * * *','select public.ft_process_report_acknowledgement_reminders();');
