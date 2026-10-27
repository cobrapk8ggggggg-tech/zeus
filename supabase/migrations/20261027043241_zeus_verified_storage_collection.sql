create table public.zeus_deleted_objects(owner uuid not null references auth.users(id) on delete cascade,digest text not null check(digest ~ '^[a-f0-9]{64}$'),immediate boolean not null default false,created_at timestamptz not null default now(),primary key(owner,digest));
alter table public.zeus_deleted_objects enable row level security;
revoke all on public.zeus_deleted_objects from public,anon,authenticated;
grant select,insert,delete on public.zeus_deleted_objects to service_role;
create table public.zeus_storage_gc_leases(owner uuid primary key references auth.users(id) on delete cascade,expires_at timestamptz not null);
alter table public.zeus_storage_gc_leases enable row level security;
revoke all on public.zeus_storage_gc_leases from public,anon,authenticated;
grant select,insert,update,delete on public.zeus_storage_gc_leases to service_role;

create or replace function public.zeus_delete_conversation(user_id uuid,conversation_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare removed bigint;
begin
 if user_id is null or conversation_id is null then raise exception 'owner_and_conversation_required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(user_id::text,74821));
 insert into public.zeus_runtime_deletions(owner,conversation) values(user_id,conversation_id) on conflict do nothing;
 insert into public.zeus_deleted_objects(owner,digest)
 select distinct user_id,ref->>'sha256' from (
  select value as document from public.zeus_runtime_records where owner=user_id and kind in ('workspace','conversation') and id=conversation_id::text
  union all select body from public.zeus_runtime_runs where owner=user_id and body->>'conversation'=conversation_id::text
 ) docs cross join lateral jsonb_path_query(document,'$.** ? (exists(@.sha256) && exists(@.bytes))') ref
 where ref->>'sha256' ~ '^[a-f0-9]{64}$' on conflict do nothing;
 insert into public.zeus_deleted_objects(owner,digest,immediate)
 select user_id,digest,true from (
  select body->'payload_archive'->>'sha256' digest from public.zeus_runtime_runs where owner=user_id and body->>'conversation'=conversation_id::text
  union all select x->'ref'->>'sha256' from public.zeus_runtime_runs r cross join lateral jsonb_array_elements(coalesce(r.body->'event_archives','[]'::jsonb)) x where r.owner=user_id and r.body->>'conversation'=conversation_id::text
  union all select x->>'sha256' from public.zeus_runtime_records r cross join lateral jsonb_array_elements(coalesce(r.value->'archives','[]'::jsonb)) x where r.owner=user_id and r.kind='conversation' and r.id=conversation_id::text
 ) refs where digest ~ '^[a-f0-9]{64}$' on conflict(owner,digest) do update set immediate=true;
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
 if command='gc_end' then delete from public.zeus_storage_gc_leases where owner=u; return 'true'::jsonb; end if;
 if command in ('gc_snapshot','gc_prepare','gc_check','gc_forget') then
  perform pg_advisory_xact_lock(hashtext('zeus_checkpoint'),hashtext(u::text));
  if command='gc_forget' then
   if exists(select 1 from storage.objects where bucket_id='zeus-private' and name=u::text||'/objects/'||(args->>'sha256')) then return jsonb_build_object('deleted',false); end if;
   perform 1 from public.zeus_storage_meter where id=1 for update;
   with removed as (delete from public.zeus_storage_reservations where owner=u and digest=args->>'sha256' returning bytes)
    select coalesce(sum(bytes),0) into n from removed;
   update public.zeus_storage_meter set used_bytes=greatest(0,used_bytes-n) where id=1;
   delete from public.zeus_deleted_objects where owner=u and digest=args->>'sha256';
   return jsonb_build_object('deleted',true,'released_bytes',n);
  end if;
  select manifest||jsonb_build_object('_revision',revision) into v from public.zeus_cloud_heads where user_id=u;
  if v is null then raise sqlstate 'PT409' using message='checkpoint_required'; end if;
  if command in ('gc_prepare','gc_check') and (v->>'_revision')::bigint<>(args->>'revision')::bigint then raise sqlstate 'PT409' using message='checkpoint_changed'; end if;
  if exists(select 1 from public.zeus_runtime_runs where owner=u and phase in ('queued','running','checkpointing','waiting_user')) then
   if command='gc_check' then return jsonb_build_object('allowed',false); end if;
   return jsonb_build_object('active',true,'revision',(v->>'_revision')::bigint);
  end if;
  if command='gc_check' then
   if not exists(select 1 from public.zeus_storage_gc_leases where owner=u and expires_at>now()) then return jsonb_build_object('allowed',false); end if;
   if coalesce(args->>'sha256','') !~ '^[a-f0-9]{64}$' then raise sqlstate 'PT400' using message='invalid_digest'; end if;
   return jsonb_build_object('allowed',
    exists(select 1 from public.zeus_storage_reservations s where s.owner=u and s.digest=args->>'sha256'
     and (s.created_at<now()-interval '24 hours' or exists(select 1 from public.zeus_deleted_objects d where d.owner=u and d.digest=s.digest and d.immediate and d.created_at>=s.created_at)))
    and not exists(select 1 from public.zeus_runtime_records where owner=u and position((args->>'sha256') in value::text)>0)
    and not exists(select 1 from public.zeus_runtime_runs where owner=u and position((args->>'sha256') in body::text)>0)
    and not exists(select 1 from public.zeus_cloud_versions where user_id=u and position((args->>'sha256') in manifest::text)>0));
  end if;
  if command='gc_prepare' then
   insert into public.zeus_storage_gc_leases(owner,expires_at) values(u,now()+interval '2 minutes') on conflict(owner) do update set expires_at=excluded.expires_at;
  end if;
  if command='gc_prepare' and coalesce((args->>'prune')::boolean,false) then
   select count(*) into n from public.zeus_runtime_deletions where owner=u;
   if n<=0 or n<>(args->>'epoch')::bigint or coalesce((v->>'deletionEpoch')::bigint,0)<>n then raise sqlstate 'PT409' using message='clean_archive_required'; end if;
   if jsonb_array_length(args->'candidates')>10000 then raise sqlstate 'PT400' using message='collection_limit'; end if;
   insert into public.zeus_deleted_objects(owner,digest,immediate)
    select u,d,true from jsonb_array_elements_text(args->'candidates') d where d ~ '^[a-f0-9]{64}$' on conflict(owner,digest) do update set immediate=true;
   delete from public.zeus_cloud_versions where user_id=u and revision<(v->>'_revision')::bigint;
  end if;
  return jsonb_build_object('revision',(v->>'_revision')::bigint,'native',v->'native',
   'deletion_epoch',(select count(*) from public.zeus_runtime_deletions where owner=u),
   'native_refs',(select coalesce(jsonb_agg(distinct manifest->'native'),'[]'::jsonb) from public.zeus_cloud_versions where user_id=u and jsonb_typeof(manifest->'native')='object'),
   'roots',(select coalesce(jsonb_agg(distinct ref),'[]'::jsonb) from (
     select value as document from public.zeus_runtime_records where owner=u
     union all select body from public.zeus_runtime_runs where owner=u
     union all select manifest from public.zeus_cloud_versions where user_id=u
    ) docs cross join lateral jsonb_path_query(document,'$.** ? (exists(@.sha256) && exists(@.bytes))') ref),
   'candidates',(select coalesce(jsonb_agg(jsonb_build_object('sha256',digest,'bytes',bytes)),'[]'::jsonb) from (
    select s.digest,s.bytes from public.zeus_storage_reservations s where s.owner=u and
    (s.created_at<now()-interval '24 hours' or exists(select 1 from public.zeus_deleted_objects d where d.owner=u and d.digest=s.digest and d.immediate and d.created_at>=s.created_at)) order by s.created_at limit 100
   ) objects));
 end if;
 if command in ('create_run','put') and exists(select 1 from public.zeus_storage_gc_leases where owner=u and expires_at>now()) then raise sqlstate 'PT409' using message='storage_cleanup_in_progress'; end if;
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
grant select on public.zeus_storage_gc_leases to authenticated;
create policy zeus_gc_lease_owner_read on public.zeus_storage_gc_leases for select to authenticated using ((select auth.uid())=owner);
grant select on public.zeus_runtime_deletions to authenticated;
create policy zeus_deleted_ids_read on public.zeus_runtime_deletions for select to authenticated using ((select auth.uid())=owner);
create or replace function public.zeus_commit_checkpoint(expected_revision bigint, operation_id uuid, snapshot jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare owner_id uuid := auth.uid(); current_revision bigint; saved public.zeus_cloud_versions;
begin
  if owner_id is null then raise sqlstate 'PT401' using message = 'authentication_required'; end if;
  if $1 is null or $1 < 0 or $2 is null or $3 is null or jsonb_typeof($3) is distinct from 'object'
     or $3->>'version' is distinct from '1' or jsonb_typeof($3->'browser') is distinct from 'object'
     or coalesce($3->'browser'->>'sha256', '') !~ '^[0-9a-f]{64}$'
     or jsonb_typeof($3->'browser'->'bytes') is distinct from 'number'
     or ($3->'browser'->>'bytes')::bigint not between 0 and 8388608
     or octet_length($3::text) > 262144 then
    raise sqlstate 'PT400' using message = 'invalid_checkpoint';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('zeus_checkpoint'), pg_catalog.hashtext(owner_id::text));
  select * into saved from public.zeus_cloud_versions v where v.user_id = owner_id and v.operation_id = $2;
  if found then
    if saved.manifest <> $3 then raise sqlstate 'PT409' using message = 'operation_reused'; end if;
    return jsonb_build_object('revision', saved.revision, 'manifest', saved.manifest, 'operation_id', saved.operation_id);
  end if;
  select h.revision into current_revision from public.zeus_cloud_heads h where h.user_id = owner_id;
  current_revision := coalesce(current_revision, 0);
  if coalesce(($3->>'deletionEpoch')::bigint,0)<(select count(*) from public.zeus_runtime_deletions where owner=owner_id)
    and $3->'native' is distinct from (select manifest->'native' from public.zeus_cloud_heads where user_id=owner_id) then
     raise sqlstate 'PT409' using message='refresh_deleted_conversations_before_archive'; end if;
  if exists(select 1 from public.zeus_storage_gc_leases where owner=owner_id and expires_at>now()) then raise sqlstate 'PT409' using message='storage_cleanup_in_progress'; end if;
  if current_revision <> $1 then raise sqlstate 'PT409' using message = 'checkpoint_conflict'; end if;
  insert into public.zeus_cloud_versions(user_id, revision, operation_id, manifest)
    values (owner_id, current_revision + 1, $2, $3) returning * into saved;
  insert into public.zeus_cloud_heads(user_id, revision, operation_id, manifest)
    values (owner_id, saved.revision, saved.operation_id, saved.manifest)
    on conflict (user_id) do update set revision = excluded.revision, operation_id = excluded.operation_id,
      manifest = excluded.manifest, updated_at = now();
  -- Only metadata expires; blob collection must prove all references are gone.
  delete from public.zeus_cloud_versions v where v.user_id = owner_id and v.revision < saved.revision - 4;
  return jsonb_build_object('revision', saved.revision, 'manifest', saved.manifest, 'operation_id', saved.operation_id);
end $$;
revoke all on function public.zeus_commit_checkpoint(bigint, uuid, jsonb) from public, anon;
grant execute on function public.zeus_commit_checkpoint(bigint, uuid, jsonb) to authenticated;


create or replace function public.zeus_reserve_object(user_id uuid,object_sha text,object_bytes bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare global_bytes bigint; owner_bytes bigint; previous bigint;
begin
 if exists(select 1 from public.zeus_storage_gc_leases where owner=user_id and expires_at>now()) then raise sqlstate 'PT409' using message='storage_cleanup_in_progress'; end if;
 if user_id is null or object_sha is null or object_sha !~ '^[a-f0-9]{64}$' or object_bytes is null or object_bytes not between 0 and 8388608 then
  raise sqlstate 'PT400' using message='invalid_object_reservation'; end if;
 select used_bytes into global_bytes from public.zeus_storage_meter where id=1 for update;
 -- Release only reservations whose upload never created an object, after a
 -- full day of inactivity. Existing objects are never deleted by this path.
 with released as (
  delete from public.zeus_storage_reservations r where r.created_at<now()-interval '24 hours'
   and not exists(select 1 from storage.objects o where o.bucket_id='zeus-private' and o.name=r.owner::text||'/objects/'||r.digest)
  returning bytes
 ) select coalesce(sum(bytes),0) into previous from released;
 update public.zeus_storage_meter set used_bytes=greatest(0,used_bytes-previous) where id=1 returning used_bytes into global_bytes;
 select bytes into previous from public.zeus_storage_reservations where owner=user_id and digest=object_sha;
 select coalesce(sum(bytes),0) into owner_bytes from public.zeus_storage_reservations where owner=user_id;
 if found and previous is not null then
  if previous<>object_bytes then raise sqlstate 'PT409' using message='object_size_conflict'; end if;
  update public.zeus_storage_reservations set created_at=now() where owner=user_id and digest=object_sha;
 else
  if global_bytes+object_bytes>838860800 or owner_bytes+object_bytes>629145600 then
   raise sqlstate 'PT507' using message='storage_allowance_reached'; end if;
  insert into public.zeus_storage_reservations(owner,digest,bytes) values(user_id,object_sha,object_bytes);
  update public.zeus_storage_meter set used_bytes=used_bytes+object_bytes where id=1;
  owner_bytes := owner_bytes+object_bytes;
 end if;
 return jsonb_build_object('used',owner_bytes,'limit',629145600,'verified_reservation',true);
end $$;

