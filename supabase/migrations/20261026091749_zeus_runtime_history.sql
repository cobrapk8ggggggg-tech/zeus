create index zeus_runtime_runs_conversation on public.zeus_runtime_runs(owner,(body->>'conversation'),created_at desc,id desc);
create or replace function public.zeus_runtime_command(command text,args jsonb)
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
 if command='list_runs' then
   select coalesce(jsonb_agg(body||jsonb_build_object('seq',seq)),'[]'::jsonb) into v from
    (select body,seq from public.zeus_runtime_runs where owner=u and body->>'conversation'=i
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
