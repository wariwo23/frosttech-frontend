create table if not exists public.ft_corporate_governance_archive (
 id uuid primary key default gen_random_uuid(),
 archive_ref text not null unique default ('FT-ARCH-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
 archive_category text not null check (archive_category in ('annual_review','board_approval','statutory_filing','management_declaration','supporting_evidence','corporate_record')),
 title text not null check (length(btrim(title)) between 3 and 240),
 description text,
 annual_review_id uuid references public.ft_statutory_annual_reviews(id) on delete restrict,
 filing_id uuid references public.ft_corporate_statutory_filings(id) on delete restrict,
 document_id uuid references public.ft_document_records(id) on delete restrict,
 archive_year integer check (archive_year between 1900 and 2200),
 confidentiality text not null default 'restricted' check (confidentiality in ('restricted','confidential','highly_confidential')),
 indexed_by uuid not null references auth.users(id) on delete restrict,
 indexed_at timestamptz not null default now(),
 constraint ft_corp_archive_source_check check (num_nonnulls(annual_review_id,filing_id,document_id)>=1)
);
create index if not exists ft_corp_archive_year_idx on public.ft_corporate_governance_archive(archive_year desc,indexed_at desc);
create index if not exists ft_corp_archive_review_idx on public.ft_corporate_governance_archive(annual_review_id) where annual_review_id is not null;
create index if not exists ft_corp_archive_filing_idx on public.ft_corporate_governance_archive(filing_id) where filing_id is not null;
create index if not exists ft_corp_archive_document_idx on public.ft_corporate_governance_archive(document_id) where document_id is not null;
alter table public.ft_corporate_governance_archive enable row level security;
revoke all on public.ft_corporate_governance_archive from public,anon,authenticated;
grant select on public.ft_corporate_governance_archive to authenticated;
create policy ft_corp_archive_super_read on public.ft_corporate_governance_archive for select to authenticated using (public.is_super_admin());

create table if not exists public.ft_corporate_governance_archive_events (
 id uuid primary key default gen_random_uuid(),
 archive_id uuid not null references public.ft_corporate_governance_archive(id) on delete restrict,
 event_type text not null check (event_type in ('entry_created')),
 actor_user_id uuid not null references auth.users(id) on delete restrict,
 event_snapshot jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists ft_corp_archive_events_idx on public.ft_corporate_governance_archive_events(archive_id,created_at);
alter table public.ft_corporate_governance_archive_events enable row level security;
revoke all on public.ft_corporate_governance_archive_events from public,anon,authenticated;
grant select on public.ft_corporate_governance_archive_events to authenticated;
create policy ft_corp_archive_events_super_read on public.ft_corporate_governance_archive_events for select to authenticated using (public.is_super_admin());

create or replace function public.ft_block_governance_archive_mutation()
returns trigger language plpgsql set search_path='public','pg_temp' as $$
begin raise exception 'Governance archive records are immutable; create a new linked entry to correct or supplement a record'; end;$$;
create trigger ft_governance_archive_immutable before update or delete on public.ft_corporate_governance_archive for each row execute function public.ft_block_governance_archive_mutation();
create trigger ft_governance_archive_events_immutable before update or delete on public.ft_corporate_governance_archive_events for each row execute function public.ft_block_governance_archive_mutation();

create or replace function public.ft_add_governance_archive_entry(
 p_archive_category text,p_title text,p_description text default null,
 p_annual_review_id uuid default null,p_filing_id uuid default null,
 p_document_id uuid default null,p_archive_year integer default null,
 p_confidentiality text default 'restricted'
) returns uuid language plpgsql security definer set search_path='public','pg_temp' as $$
declare v_id uuid;v_snapshot jsonb;
begin
 if auth.uid() is null or not public.is_super_admin() then raise exception 'Super Administrator authorization required'; end if;
 if num_nonnulls(p_annual_review_id,p_filing_id,p_document_id)<1 then raise exception 'Link at least one existing review, filing or document'; end if;
 if p_annual_review_id is not null and not exists(select 1 from public.ft_statutory_annual_reviews where id=p_annual_review_id) then raise exception 'Annual review not found'; end if;
 if p_filing_id is not null and not exists(select 1 from public.ft_corporate_statutory_filings where id=p_filing_id) then raise exception 'Statutory filing not found'; end if;
 if p_document_id is not null and not exists(select 1 from public.ft_document_records where id=p_document_id and record_status='active' and disposed_at is null) then raise exception 'Active, undisposed document not found'; end if;
 if nullif(btrim(p_title),'') is null then raise exception 'Archive title is required'; end if;
 if p_archive_category not in ('annual_review','board_approval','statutory_filing','management_declaration','supporting_evidence','corporate_record') then raise exception 'Invalid archive category'; end if;
 if p_confidentiality not in ('restricted','confidential','highly_confidential') then raise exception 'Invalid confidentiality level'; end if;
 insert into public.ft_corporate_governance_archive(archive_category,title,description,annual_review_id,filing_id,document_id,archive_year,confidentiality,indexed_by)
 values(p_archive_category,btrim(p_title),nullif(btrim(p_description),''),p_annual_review_id,p_filing_id,p_document_id,p_archive_year,p_confidentiality,auth.uid())
 returning id into v_id;
 select to_jsonb(a) into v_snapshot from public.ft_corporate_governance_archive a where a.id=v_id;
 insert into public.ft_corporate_governance_archive_events(archive_id,event_type,actor_user_id,event_snapshot) values(v_id,'entry_created',auth.uid(),v_snapshot);
 return v_id;
end;$$;
revoke all on function public.ft_add_governance_archive_entry(text,text,text,uuid,uuid,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.ft_add_governance_archive_entry(text,text,text,uuid,uuid,uuid,integer,text) to authenticated;
revoke all on function public.ft_block_governance_archive_mutation() from public,anon,authenticated;