create table if not exists public.ft_board_meetings (
 id uuid primary key default gen_random_uuid(),
 meeting_ref text not null unique default ('FT-BM-'||to_char(now(),'YYYY')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8))),
 meeting_title text not null check(length(btrim(meeting_title)) between 3 and 240),
 meeting_type text not null check(meeting_type in ('board','management','committee','special')),
 meeting_status text not null default 'draft' check(meeting_status in ('draft','scheduled','held','minutes_approved','cancelled')),
 scheduled_at timestamptz,venue_or_link text,notice_issued_at timestamptz,
 agenda jsonb not null default '[]'::jsonb,minutes_text text,
 minutes_document_id uuid references public.ft_document_records(id) on delete restrict,
 minutes_approved_by uuid references auth.users(id) on delete restrict,minutes_approved_at timestamptz,
 created_by uuid not null references auth.users(id) on delete restrict,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 check(meeting_status<>'minutes_approved' or (minutes_approved_by is not null and minutes_approved_at is not null and nullif(btrim(minutes_text),'') is not null))
);
create table if not exists public.ft_board_meeting_attendees (
 id uuid primary key default gen_random_uuid(),meeting_id uuid not null references public.ft_board_meetings(id) on delete restrict,
 attendee_name text not null check(length(btrim(attendee_name)) between 2 and 160),attendee_role text,
 attendance_status text not null default 'invited' check(attendance_status in ('invited','present','absent','apology')),
 attendance_note text,recorded_by uuid not null references auth.users(id) on delete restrict,recorded_at timestamptz not null default now(),
 unique(meeting_id,attendee_name)
);
create table if not exists public.ft_board_resolutions (
 id uuid primary key default gen_random_uuid(),
 resolution_ref text not null unique default ('FT-RES-'||to_char(now(),'YYYY')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8))),
 meeting_id uuid not null references public.ft_board_meetings(id) on delete restrict,
 resolution_title text not null check(length(btrim(resolution_title)) between 3 and 240),resolution_text text not null check(length(btrim(resolution_text))>=10),
 resolution_status text not null default 'proposed' check(resolution_status in ('proposed','approved','rejected','deferred','executed')),
 proposed_by uuid not null references auth.users(id) on delete restrict,decided_by uuid references auth.users(id) on delete restrict,decided_at timestamptz,
 execution_note text,execution_recorded_by uuid references auth.users(id) on delete restrict,execution_recorded_at timestamptz,
 supporting_document_id uuid references public.ft_document_records(id) on delete restrict,archive_entry_id uuid references public.ft_corporate_governance_archive(id) on delete restrict,created_at timestamptz not null default now(),
 check((resolution_status in ('approved','rejected','deferred','executed') and decided_by is not null and decided_at is not null) or resolution_status='proposed'),
 check(resolution_status<>'executed' or (execution_recorded_by is not null and execution_recorded_at is not null and nullif(btrim(execution_note),'') is not null))
);
create table if not exists public.ft_board_governance_events (
 id uuid primary key default gen_random_uuid(),meeting_id uuid references public.ft_board_meetings(id) on delete restrict,resolution_id uuid references public.ft_board_resolutions(id) on delete restrict,
 event_type text not null check(event_type in ('meeting_created','meeting_updated','attendee_recorded','minutes_approved','resolution_proposed','resolution_decided','resolution_execution_recorded')),
 actor_user_id uuid not null references auth.users(id) on delete restrict,event_snapshot jsonb not null,created_at timestamptz not null default now(),
 check(num_nonnulls(meeting_id,resolution_id)>=1)
);
create index if not exists ft_board_meetings_date_idx on public.ft_board_meetings(scheduled_at desc);
create index if not exists ft_board_meeting_attendees_idx on public.ft_board_meeting_attendees(meeting_id);
create index if not exists ft_board_resolutions_meeting_idx on public.ft_board_resolutions(meeting_id,created_at desc);
create index if not exists ft_board_events_meeting_idx on public.ft_board_governance_events(meeting_id,created_at desc);
create index if not exists ft_board_events_resolution_idx on public.ft_board_governance_events(resolution_id,created_at desc);
alter table public.ft_board_meetings enable row level security;
alter table public.ft_board_meeting_attendees enable row level security;
alter table public.ft_board_resolutions enable row level security;
alter table public.ft_board_governance_events enable row level security;
revoke all on public.ft_board_meetings,public.ft_board_meeting_attendees,public.ft_board_resolutions,public.ft_board_governance_events from public,anon,authenticated;
grant select on public.ft_board_meetings,public.ft_board_meeting_attendees,public.ft_board_resolutions,public.ft_board_governance_events to authenticated;
drop policy if exists ft_board_meetings_super_read on public.ft_board_meetings;
create policy ft_board_meetings_super_read on public.ft_board_meetings for select to authenticated using(public.is_super_admin());
drop policy if exists ft_board_attendees_super_read on public.ft_board_meeting_attendees;
create policy ft_board_attendees_super_read on public.ft_board_meeting_attendees for select to authenticated using(public.is_super_admin());
drop policy if exists ft_board_resolutions_super_read on public.ft_board_resolutions;
create policy ft_board_resolutions_super_read on public.ft_board_resolutions for select to authenticated using(public.is_super_admin());
drop policy if exists ft_board_events_super_read on public.ft_board_governance_events;
create policy ft_board_events_super_read on public.ft_board_governance_events for select to authenticated using(public.is_super_admin());

create or replace function public.ft_board_create_meeting(p_title text,p_type text,p_scheduled_at timestamptz default null,p_venue_or_link text default null,p_notice_issued_at timestamptz default null,p_agenda jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path='public','pg_temp' as $$
declare v_id uuid;v jsonb;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if nullif(btrim(p_title),'') is null or p_type not in ('board','management','committee','special') then raise exception 'Valid meeting title and type are required'; end if;
 if jsonb_typeof(coalesce(p_agenda,'[]'::jsonb))<>'array' then raise exception 'Agenda must be a JSON array'; end if;
 insert into public.ft_board_meetings(meeting_title,meeting_type,scheduled_at,venue_or_link,notice_issued_at,agenda,created_by)
 values(btrim(p_title),p_type,p_scheduled_at,nullif(btrim(p_venue_or_link),''),p_notice_issued_at,coalesce(p_agenda,'[]'::jsonb),auth.uid()) returning id into v_id;
 select to_jsonb(m) into v from public.ft_board_meetings m where m.id=v_id;
 insert into public.ft_board_governance_events(meeting_id,event_type,actor_user_id,event_snapshot) values(v_id,'meeting_created',auth.uid(),v);return v_id;
end;$$;

create or replace function public.ft_board_record_attendee(p_meeting_id uuid,p_name text,p_role text,p_status text,p_note text default null)
returns uuid language plpgsql security definer set search_path='public','pg_temp' as $$
declare v_id uuid;v jsonb;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if not exists(select 1 from public.ft_board_meetings where id=p_meeting_id and meeting_status not in ('cancelled','minutes_approved')) then raise exception 'Meeting not found or closed'; end if;
 insert into public.ft_board_meeting_attendees(meeting_id,attendee_name,attendee_role,attendance_status,attendance_note,recorded_by)
 values(p_meeting_id,btrim(p_name),nullif(btrim(p_role),''),p_status,nullif(btrim(p_note),''),auth.uid()) returning id into v_id;
 select to_jsonb(a) into v from public.ft_board_meeting_attendees a where a.id=v_id;
 insert into public.ft_board_governance_events(meeting_id,event_type,actor_user_id,event_snapshot) values(p_meeting_id,'attendee_recorded',auth.uid(),v);return v_id;
end;$$;

create or replace function public.ft_board_propose_resolution(p_meeting_id uuid,p_title text,p_text text,p_supporting_document_id uuid default null)
returns uuid language plpgsql security definer set search_path='public','pg_temp' as $$
declare v_id uuid;v jsonb;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if not exists(select 1 from public.ft_board_meetings where id=p_meeting_id and meeting_status in ('held','minutes_approved')) then raise exception 'Resolutions can only be recorded against a meeting marked held or minutes approved'; end if;
 if p_supporting_document_id is not null and not exists(select 1 from public.ft_document_records where id=p_supporting_document_id and record_status='active' and disposed_at is null) then raise exception 'Supporting document is not active'; end if;
 insert into public.ft_board_resolutions(meeting_id,resolution_title,resolution_text,proposed_by,supporting_document_id) values(p_meeting_id,btrim(p_title),btrim(p_text),auth.uid(),p_supporting_document_id) returning id into v_id;
 select to_jsonb(r) into v from public.ft_board_resolutions r where r.id=v_id;
 insert into public.ft_board_governance_events(meeting_id,resolution_id,event_type,actor_user_id,event_snapshot) values(p_meeting_id,v_id,'resolution_proposed',auth.uid(),v);return v_id;
end;$$;

create or replace function public.ft_board_decide_resolution(p_resolution_id uuid,p_decision text,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='public','pg_temp' as $$
declare v public.ft_board_resolutions%rowtype;snap jsonb;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if p_decision not in ('approved','rejected','deferred') then raise exception 'Decision must be approved, rejected or deferred'; end if;
 select * into v from public.ft_board_resolutions where id=p_resolution_id for update;
 if not found or v.resolution_status<>'proposed' then raise exception 'Only a proposed resolution can receive a decision'; end if;
 update public.ft_board_resolutions set resolution_status=p_decision,decided_by=auth.uid(),decided_at=now(),execution_note=case when p_decision='rejected' then nullif(btrim(p_reason),'') else execution_note end where id=p_resolution_id returning * into v;
 snap:=to_jsonb(v)||jsonb_build_object('decision_reason',nullif(btrim(p_reason),''));
 insert into public.ft_board_governance_events(meeting_id,resolution_id,event_type,actor_user_id,event_snapshot) values(v.meeting_id,p_resolution_id,'resolution_decided',auth.uid(),snap);
 return jsonb_build_object('success',true,'resolution_ref',v.resolution_ref,'status',v.resolution_status);
end;$$;

create or replace function public.ft_board_record_resolution_execution(p_resolution_id uuid,p_execution_note text,p_archive_entry_id uuid default null)
returns jsonb language plpgsql security definer set search_path='public','pg_temp' as $$
declare v public.ft_board_resolutions%rowtype;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if nullif(btrim(p_execution_note),'') is null then raise exception 'Execution evidence or note is required'; end if;
 select * into v from public.ft_board_resolutions where id=p_resolution_id for update;
 if not found or v.resolution_status<>'approved' then raise exception 'Only an approved resolution can be marked executed'; end if;
 if p_archive_entry_id is not null and not exists(select 1 from public.ft_corporate_governance_archive where id=p_archive_entry_id) then raise exception 'Archive entry not found'; end if;
 update public.ft_board_resolutions set resolution_status='executed',execution_note=btrim(p_execution_note),execution_recorded_by=auth.uid(),execution_recorded_at=now(),archive_entry_id=p_archive_entry_id where id=p_resolution_id returning * into v;
 insert into public.ft_board_governance_events(meeting_id,resolution_id,event_type,actor_user_id,event_snapshot) values(v.meeting_id,v.id,'resolution_execution_recorded',auth.uid(),to_jsonb(v));
 return jsonb_build_object('success',true,'resolution_ref',v.resolution_ref,'status',v.resolution_status);
end;$$;

create or replace function public.ft_board_approve_minutes(p_meeting_id uuid,p_minutes_text text,p_minutes_document_id uuid default null)
returns jsonb language plpgsql security definer set search_path='public','pg_temp' as $$
declare v public.ft_board_meetings%rowtype;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if nullif(btrim(p_minutes_text),'') is null then raise exception 'Meeting minutes are required'; end if;
 if p_minutes_document_id is not null and not exists(select 1 from public.ft_document_records where id=p_minutes_document_id and record_status='active' and disposed_at is null) then raise exception 'Minutes document is not active'; end if;
 select * into v from public.ft_board_meetings where id=p_meeting_id for update;
 if not found or v.meeting_status not in ('held','scheduled') then raise exception 'Only a held meeting can have its minutes approved'; end if;
 update public.ft_board_meetings set meeting_status='minutes_approved',minutes_text=btrim(p_minutes_text),minutes_document_id=p_minutes_document_id,minutes_approved_by=auth.uid(),minutes_approved_at=now(),updated_at=now() where id=p_meeting_id returning * into v;
 insert into public.ft_board_governance_events(meeting_id,event_type,actor_user_id,event_snapshot) values(v.id,'minutes_approved',auth.uid(),to_jsonb(v));
 return jsonb_build_object('success',true,'meeting_ref',v.meeting_ref,'status',v.meeting_status);
end;$$;

create or replace function public.ft_board_set_meeting_status(p_meeting_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path='public','pg_temp' as $$
declare v public.ft_board_meetings%rowtype;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if p_status not in ('scheduled','held','cancelled') then raise exception 'Unsupported meeting status'; end if;
 select * into v from public.ft_board_meetings where id=p_meeting_id for update;
 if not found or v.meeting_status not in ('draft','scheduled') then raise exception 'Meeting status cannot be changed from its current state'; end if;
 update public.ft_board_meetings set meeting_status=p_status,updated_at=now() where id=p_meeting_id returning * into v;
 insert into public.ft_board_governance_events(meeting_id,event_type,actor_user_id,event_snapshot) values(v.id,'meeting_updated',auth.uid(),to_jsonb(v));
 return jsonb_build_object('success',true,'meeting_ref',v.meeting_ref,'status',v.meeting_status);
end;$$;

revoke all on function public.ft_board_create_meeting(text,text,timestamptz,text,timestamptz,jsonb) from public,anon,authenticated;
revoke all on function public.ft_board_record_attendee(uuid,text,text,text,text) from public,anon,authenticated;
revoke all on function public.ft_board_propose_resolution(uuid,text,text,uuid) from public,anon,authenticated;
revoke all on function public.ft_board_decide_resolution(uuid,text,text) from public,anon,authenticated;
revoke all on function public.ft_board_record_resolution_execution(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.ft_board_approve_minutes(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.ft_board_set_meeting_status(uuid,text) from public,anon,authenticated;
grant execute on function public.ft_board_create_meeting(text,text,timestamptz,text,timestamptz,jsonb),public.ft_board_record_attendee(uuid,text,text,text,text),public.ft_board_propose_resolution(uuid,text,text,uuid),public.ft_board_decide_resolution(uuid,text,text),public.ft_board_record_resolution_execution(uuid,text,uuid),public.ft_board_approve_minutes(uuid,text,uuid),public.ft_board_set_meeting_status(uuid,text) to authenticated;