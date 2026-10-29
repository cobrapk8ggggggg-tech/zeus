-- Bounded application-only gateway storage. Atlas remains an adapter; this
-- path keeps the personal runtime usable when Atlas provisioning is blocked.
create table public.zeus_runtime_access (
 token_sha256 text primary key check(token_sha256 ~ '^[a-f0-9]{64}$'),
 label text not null, created_at timestamptz not null default now(), revoked_at timestamptz
);
create table public.zeus_runtime_records (
 owner uuid not null references auth.users(id) on delete cascade,
 kind text not null, id text not null, value jsonb not null check(octet_length(value::text)<=8388608),
 updated_at timestamptz not null default now(), primary key(owner,kind,id)
);
create table public.zeus_runtime_runs (
 owner uuid not null references auth.users(id) on delete cascade,
 id uuid not null, phase text not null, seq bigint not null default 0,
 body jsonb not null check(octet_length(body::text)<=8388608),
 created_at timestamptz not null default now(), primary key(owner,id)
);
create index zeus_runtime_runs_queue on public.zeus_runtime_runs(phase,created_at);
create table public.zeus_runtime_events (
 owner uuid not null, run uuid not null, seq bigint not null, value jsonb not null check(octet_length(value::text)<=262144),
 primary key(owner,run,seq), foreign key(owner,run) references public.zeus_runtime_runs(owner,id) on delete cascade
);
alter table public.zeus_runtime_access enable row level security;
alter table public.zeus_runtime_records enable row level security;
alter table public.zeus_runtime_runs enable row level security;
alter table public.zeus_runtime_events enable row level security;
revoke all on public.zeus_runtime_access,public.zeus_runtime_records,public.zeus_runtime_runs,public.zeus_runtime_events from public,anon,authenticated;
grant select on public.zeus_runtime_access to service_role;
grant select,insert,update,delete on public.zeus_runtime_records,public.zeus_runtime_runs,public.zeus_runtime_events to service_role;
create policy zeus_runtime_access_no_client on public.zeus_runtime_access for all to anon,authenticated using(false) with check(false);
create policy zeus_runtime_records_no_client on public.zeus_runtime_records for all to anon,authenticated using(false) with check(false);
create policy zeus_runtime_runs_no_client on public.zeus_runtime_runs for all to anon,authenticated using(false) with check(false);
create policy zeus_runtime_events_no_client on public.zeus_runtime_events for all to anon,authenticated using(false) with check(false);

create function public.zeus_runtime_command(command text,args jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 u uuid; k text; i text; r public.zeus_runtime_runs; v jsonb; n bigint;
begin
 if command in ('ping','initialize') then return 'true'::jsonb; end if;
 if command='claim' then
   select * into r from public.zeus_runtime_runs where phase='queued' order by created_at for update skip locked limit 1;
   if not found then return 'null'::jsonb; end if;
   update public.zeus_runtime_runs set phase='running',body=body||jsonb_build_object('status','running','updated',extract(epoch from now())) where owner=r.owner and id=r.id returning * into r;
   return r.body||jsonb_build_object('owner',r.owner,'seq',r.seq);
 end if;
 if command='recover' then
   update public.zeus_runtime_runs set phase='interrupted',body=body||jsonb_build_object('status','interrupted','error','Worker restarted; inspect the checkpoint before resuming.') where phase in ('running','checkpointing');
   return 'true'::jsonb;
 end if;
 u := (args->>'owner')::uuid; k := args->>'kind'; i := args->>'id';
 if u is null then raise sqlstate 'PT400' using message='owner_required'; end if;
 if command='get' then select value into v from public.zeus_runtime_records where owner=u and kind=k and id=i; return coalesce(v,'null'::jsonb); end if;
 if command='put' then
   if k not in ('provider','conversation','workspace','approval') or length(i)>200 then raise sqlstate 'PT400' using message='invalid_record'; end if;
   v := (args->'value')||jsonb_build_object('owner',u,'id',i,'kind',k,'updated',extract(epoch from now()));
   insert into public.zeus_runtime_records(owner,kind,id,value) values(u,k,i,v)
    on conflict(owner,kind,id) do update set value=excluded.value,updated_at=now(); return v;
 end if;
 if command='list' then
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v from
    (select value from public.zeus_runtime_records where owner=u and kind=k order by updated_at desc limit 100) rows;
   return v;
 end if;
 if command='create_run' then
   v := (args->'value')||jsonb_build_object('owner',u);
   insert into public.zeus_runtime_runs(owner,id,phase,body) values(u,i::uuid,'queued',v) on conflict(owner,id) do nothing;
   select * into r from public.zeus_runtime_runs where owner=u and id=i::uuid;
   return r.body||jsonb_build_object('owner',u,'seq',r.seq);
 end if;
 if command='run' then
   select * into r from public.zeus_runtime_runs where owner=u and id=i::uuid;
   if not found then return 'null'::jsonb; end if;
   return r.body||jsonb_build_object('owner',u,'seq',r.seq);
 end if;
 if command='update_run' then
   update public.zeus_runtime_runs set body=body||(args->'value')||jsonb_build_object('updated',extract(epoch from now())),
    phase=coalesce(args->'value'->>'status',phase) where owner=u and id=i::uuid returning * into r;
   if not found then raise sqlstate 'PT404' using message='run_not_found'; end if;
   return r.body||jsonb_build_object('owner',u,'seq',r.seq);
 end if;
 if command='event' then
   update public.zeus_runtime_runs set seq=seq+1 where owner=u and id=i::uuid returning seq into n;
   if not found then raise sqlstate 'PT404' using message='run_not_found'; end if;
   v := jsonb_build_object('owner',u,'run',i,'seq',n,'kind',args->>'event_kind','data',args->'data','created',extract(epoch from now()));
   insert into public.zeus_runtime_events(owner,run,seq,value) values(u,i::uuid,n,v); return v;
 end if;
 if command='events' then
   select coalesce(jsonb_agg(value order by seq),'[]'::jsonb) into v from
    (select value,seq from public.zeus_runtime_events where owner=u and run=i::uuid and seq>greatest(coalesce((args->>'after')::bigint,0),0) order by seq limit 200) rows;
   return v;
 end if;
 raise sqlstate 'PT400' using message='unknown_command';
end $$;
revoke all on function public.zeus_runtime_command(text,jsonb) from public,anon,authenticated;
grant execute on function public.zeus_runtime_command(text,jsonb) to service_role;
