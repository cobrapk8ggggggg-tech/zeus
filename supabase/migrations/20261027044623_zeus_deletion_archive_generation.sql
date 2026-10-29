-- Purge old recovery checkpoints once per confirmed deletion generation.
create table public.zeus_storage_gc_state(owner uuid primary key references auth.users(id) on delete cascade,purged_epoch bigint not null default 0);
alter table public.zeus_storage_gc_state enable row level security;
revoke all on public.zeus_storage_gc_state from public,anon,authenticated;
grant select,insert,update on public.zeus_storage_gc_state to service_role;
do $$ declare source text; needle text := 'delete from public.zeus_cloud_versions where user_id=u and revision<(v->>''_revision'')::bigint;'; begin
 source:=pg_get_functiondef('public.zeus_runtime_command(text,jsonb)'::regprocedure);
 if position(needle in source)=0 then raise exception 'Unexpected runtime checkpoint branch'; end if;
 source:=replace(source,needle,'if coalesce((select purged_epoch from public.zeus_storage_gc_state where owner=u),0)<n then '||needle||' insert into public.zeus_storage_gc_state(owner,purged_epoch) values(u,n) on conflict(owner) do update set purged_epoch=excluded.purged_epoch; end if;');
 source:=replace(source,$find$'native_refs',$find$,$replacement$'purged_epoch',coalesce((select purged_epoch from public.zeus_storage_gc_state where owner=u),0),'native_refs',$replacement$);
 execute source;
end $$;
