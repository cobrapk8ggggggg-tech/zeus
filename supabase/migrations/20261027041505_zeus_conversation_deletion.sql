-- A content-free deletion marker prevents stale devices resurrecting chats.
create table public.zeus_runtime_deletions (
 owner uuid not null references auth.users(id) on delete cascade,
 conversation uuid not null, deleted_at timestamptz not null default now(),
 primary key(owner,conversation)
);
alter table public.zeus_runtime_deletions enable row level security;
revoke all on public.zeus_runtime_deletions from public,anon,authenticated;
grant select,insert on public.zeus_runtime_deletions to service_role;
create function public.zeus_delete_conversation(user_id uuid,conversation_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare removed bigint;
begin
 if user_id is null or conversation_id is null then raise exception 'owner_and_conversation_required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(user_id::text,74821));
 insert into public.zeus_runtime_deletions(owner,conversation) values(user_id,conversation_id) on conflict do nothing;
 delete from public.zeus_runtime_records where owner=user_id and kind='approval' and value->>'run' in
  (select id::text from public.zeus_runtime_runs where owner=user_id and body->>'conversation'=conversation_id::text);
 delete from public.zeus_runtime_runs where owner=user_id and body->>'conversation'=conversation_id::text;
 get diagnostics removed = row_count;
 delete from public.zeus_runtime_records where owner=user_id and kind in ('workspace','conversation') and id=conversation_id::text;
 delete from public.zeus_runtime_grants g where g.user_id=zeus_delete_conversation.user_id and g.conversation_id=zeus_delete_conversation.conversation_id;
 return jsonb_build_object('deleted',true,'runs',removed);
end $$;
revoke all on function public.zeus_delete_conversation(uuid,uuid) from public,anon,authenticated;
grant execute on function public.zeus_delete_conversation(uuid,uuid) to service_role;

create or replace function public.zeus_runtime_command(command text,args jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 u uuid; k text; i text; r public.zeus_runtime_runs; v jsonb; n bigint;
begin
 if command in ('ping','initialize') then return 'true'::jsonb; end if;
 if command='claim' then
   select * into r from public.zeus_runtime_runs where phase='queued' and not exists(select 1 from public.zeus_runtime_leases l where l.owner=zeus_runtime_runs.owner and l.expires_at>now()) order by created_at for update skip locked limit 1;
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
 if command='delete_conversation' then return public.zeus_delete_conversation(u,i::uuid); end if;
 if command='deletions' then
  select coalesce(jsonb_agg(conversation::text),'[]'::jsonb) into v from public.zeus_runtime_deletions where owner=u; return v;
 end if;
 if (command='put' and k in ('conversation','workspace') and exists(select 1 from public.zeus_runtime_deletions where owner=u and conversation::text=i)) or
  (command='create_run' and exists(select 1 from public.zeus_runtime_deletions where owner=u and conversation::text=(args->'value'->>'conversation'))) then
   raise sqlstate 'PT410' using message='conversation_deleted';
 end if;
 if command='account_state' then
   select jsonb_build_object('active_runs',(select count(*) from public.zeus_runtime_runs where owner=u and phase in ('queued','running','checkpointing','waiting_user')),
    'lease',(select jsonb_build_object('id',lease_id,'expires',extract(epoch from expires_at)) from public.zeus_runtime_leases where owner=u and expires_at>now())) into v;
   return v;
 end if;
 if command in ('begin_transition','renew_transition','end_transition') then
   perform pg_advisory_xact_lock(hashtextextended(u::text,74821));
   if command='end_transition' then
    delete from public.zeus_runtime_leases where owner=u and lease_id=i::uuid; return 'true'::jsonb;
   end if;
   if command='begin_transition' then
    if exists(select 1 from public.zeus_runtime_runs where owner=u and phase in ('queued','running','checkpointing','waiting_user')) then
     raise sqlstate 'PT409' using message='finish_cloud_runs_before_transition'; end if;
    if exists(select 1 from public.zeus_runtime_leases where owner=u and expires_at>now() and lease_id<>i::uuid) then
     raise sqlstate 'PT409' using message='another_transition_in_progress'; end if;
    insert into public.zeus_runtime_leases(owner,lease_id,expires_at) values(u,i::uuid,now()+interval '5 minutes')
     on conflict(owner) do update set lease_id=excluded.lease_id,expires_at=excluded.expires_at;
   else
    update public.zeus_runtime_leases set expires_at=now()+interval '5 minutes' where owner=u and lease_id=i::uuid and expires_at>now();
    if not found then raise sqlstate 'PT409' using message='transition_lease_expired'; end if;
   end if;
   return jsonb_build_object('id',i,'expires',extract(epoch from now()+interval '5 minutes'));
 end if;
 if command='get' then select value into v from public.zeus_runtime_records where owner=u and kind=k and id=i; return coalesce(v,'null'::jsonb); end if;
 if command='put' then
   if k not in ('provider','conversation','workspace','approval') or length(i)>200 then raise sqlstate 'PT400' using message='invalid_record'; end if;
   v := (args->'value')||jsonb_build_object('owner',u,'id',i,'kind',k,'updated',extract(epoch from now()));
   insert into public.zeus_runtime_records(owner,kind,id,value) values(u,k,i,v)
    on conflict(owner,kind,id) do update set value=excluded.value,updated_at=now(); return v;
 end if;
 if command='list_conversations' then
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v from (
     select jsonb_build_object('id',id,'title',value->'title','updated',value->'updated','native_session',value->'native_session') value
     from public.zeus_runtime_records where owner=u and kind='conversation' and id>coalesce(args->>'after','') order by id limit 100
   ) rows; return v;
 end if;
 if command='list' then
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v from
    (select value from public.zeus_runtime_records where owner=u and kind=k order by updated_at desc limit 100) rows;
   return v;
 end if;
 if command='create_run' then
   perform pg_advisory_xact_lock(hashtextextended(u::text,74821));
   if exists(select 1 from public.zeus_runtime_leases where owner=u and expires_at>now()) then raise sqlstate 'PT409' using message='account_transition_in_progress'; end if;
   v := (args->'value')||jsonb_build_object('owner',u);
   insert into public.zeus_runtime_runs(owner,id,phase,body) values(u,i::uuid,'queued',v) on conflict(owner,id) do nothing;
   select * into r from public.zeus_runtime_runs where owner=u and id=i::uuid;
   return r.body||jsonb_build_object('owner',u,'seq',r.seq);
 end if;
 if command='list_runs' then
   select coalesce(jsonb_agg(body||jsonb_build_object('seq',seq)),'[]'::jsonb) into v from
    (select jsonb_build_object('id',id,'conversation',body->>'conversation','created',body->'created','status',phase,'prompt',body->'prompt','native_user_id',body->'native_user_id','native_assistant_id',body->'native_assistant_id','error',body->'error') as body,seq from public.zeus_runtime_runs where owner=u and body->>'conversation'=i
      and created_at < to_timestamp(coalesce((args->>'before')::double precision,4102444800))
      order by created_at desc,id desc limit 25) rows;
   return v;
 end if;
 if command='prune_events' then
   select * into r from public.zeus_runtime_runs where owner=u and id=i::uuid;
   if not found or r.phase not in ('completed','failed','cancelled','interrupted') or jsonb_array_length(coalesce(r.body->'event_archives','[]'::jsonb))=0
    then raise sqlstate 'PT409' using message='verified_archive_required'; end if;
   delete from public.zeus_runtime_events where owner=u and run=i::uuid and seq<=coalesce((args->>'through')::bigint,0);
   return 'true'::jsonb;
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
