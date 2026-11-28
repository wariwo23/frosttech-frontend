create table if not exists public.ft_statutory_annual_reviews (
 id uuid primary key default gen_random_uuid(),
 review_year integer not null unique check (review_year between 2000 and 2200),
 review_status text not null default 'draft' check (review_status in ('draft','approved')),
 snapshot jsonb not null,
 snapshot_created_at timestamptz not null default now(),
 prepared_by uuid not null references auth.users(id) on delete restrict,
 approved_by uuid references auth.users(id) on delete restrict,
 approved_at timestamptz,
 management_declaration text,
 created_at timestamptz not null default now(),
 constraint ft_stat_annual_review_approval_check check (
  (review_status='draft' and approved_by is null and approved_at is null)
  or (review_status='approved' and approved_by is not null and approved_at is not null and nullif(btrim(management_declaration),'') is not null)
 )
);
create table if not exists public.ft_statutory_annual_review_events (
 id uuid primary key default gen_random_uuid(),
 annual_review_id uuid not null references public.ft_statutory_annual_reviews(id) on delete restrict,
 event_type text not null check (event_type in ('snapshot_created','review_approved')),
 actor_user_id uuid not null references auth.users(id) on delete restrict,
 event_snapshot jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists ft_stat_annual_events_review_idx on public.ft_statutory_annual_review_events(annual_review_id,created_at);
alter table public.ft_statutory_annual_reviews enable row level security;
alter table public.ft_statutory_annual_review_events enable row level security;
revoke all on public.ft_statutory_annual_reviews,public.ft_statutory_annual_review_events from public,anon,authenticated;
grant select on public.ft_statutory_annual_reviews,public.ft_statutory_annual_review_events to authenticated;
drop policy if exists ft_stat_annual_reviews_super_read on public.ft_statutory_annual_reviews;
create policy ft_stat_annual_reviews_super_read on public.ft_statutory_annual_reviews for select to authenticated using (public.is_super_admin());
drop policy if exists ft_stat_annual_events_super_read on public.ft_statutory_annual_review_events;
create policy ft_stat_annual_events_super_read on public.ft_statutory_annual_review_events for select to authenticated using (public.is_super_admin());
create or replace function public.ft_create_statutory_annual_review(p_review_year integer)
returns uuid language plpgsql security definer set search_path='public','pg_temp' as $$
declare v_id uuid;v_snapshot jsonb;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if p_review_year<2000 or p_review_year>2200 then raise exception 'Invalid review year'; end if;
 select jsonb_build_object('review_year',p_review_year,'generated_at',now(),'scope','Statutory filing records with due date or reporting period end in the selected calendar year','filing_count',count(*),'filings',coalesce(jsonb_agg(to_jsonb(v) order by v.due_date,v.filing_id),'[]'::jsonb),'escalation_count',coalesce(sum(v.escalation_count),0),'overdue_count',count(*) filter(where v.monitoring_status='overdue'),'payment_variance_count',count(*) filter(where v.payment_reconciliation_status='variance'),'completed_count',count(*) filter(where v.monitoring_status='completed'),'unresolved_count',count(*) filter(where v.monitoring_status in ('overdue','due_within_30_days','awaiting_acknowledgement','accepted_awaiting_closure')))
 into v_snapshot from public.ft_statutory_compliance_board_report_v v
 where extract(year from v.due_date)=p_review_year or extract(year from v.reporting_period_end)=p_review_year;
 insert into public.ft_statutory_annual_reviews(review_year,snapshot,prepared_by) values(p_review_year,v_snapshot,auth.uid()) returning id into v_id;
 insert into public.ft_statutory_annual_review_events(annual_review_id,event_type,actor_user_id,event_snapshot) values(v_id,'snapshot_created',auth.uid(),v_snapshot);
 return v_id;
exception when unique_violation then raise exception 'An annual review snapshot already exists for year %; existing snapshot was preserved',p_review_year;
end;$$;
create or replace function public.ft_approve_statutory_annual_review(p_review_id uuid,p_management_declaration text)
returns jsonb language plpgsql security definer set search_path='public','pg_temp' as $$
declare v_review public.ft_statutory_annual_reviews%rowtype;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if nullif(btrim(p_management_declaration),'') is null then raise exception 'A management declaration is required'; end if;
 select * into v_review from public.ft_statutory_annual_reviews where id=p_review_id for update;
 if not found then raise exception 'Annual review not found'; end if;
 if v_review.review_status<>'draft' then raise exception 'Only a draft annual review can be approved'; end if;
 update public.ft_statutory_annual_reviews set review_status='approved',approved_by=auth.uid(),approved_at=now(),management_declaration=btrim(p_management_declaration) where id=p_review_id;
 insert into public.ft_statutory_annual_review_events(annual_review_id,event_type,actor_user_id,event_snapshot) values(p_review_id,'review_approved',auth.uid(),jsonb_build_object('review_year',v_review.review_year,'approved_at',now(),'management_declaration',btrim(p_management_declaration),'snapshot_created_at',v_review.snapshot_created_at));
 return jsonb_build_object('success',true,'review_id',p_review_id,'review_year',v_review.review_year,'approved_at',now());
end;$$;
revoke all on function public.ft_create_statutory_annual_review(integer) from public,anon,authenticated;
revoke all on function public.ft_approve_statutory_annual_review(uuid,text) from public,anon,authenticated;
grant execute on function public.ft_create_statutory_annual_review(integer) to authenticated;
grant execute on function public.ft_approve_statutory_annual_review(uuid,text) to authenticated;