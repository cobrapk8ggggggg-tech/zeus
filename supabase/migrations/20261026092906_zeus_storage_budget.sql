-- A reserved upper bound keeps the personal free project below its storage
-- allowance. Reservation failures never authorize deleting local originals.
create table public.zeus_storage_meter (
 id smallint primary key check(id=1), used_bytes bigint not null default 0 check(used_bytes>=0)
);
insert into public.zeus_storage_meter(id) values(1);
create table public.zeus_storage_reservations (
 owner uuid not null references auth.users(id) on delete cascade,
 digest text not null check(digest ~ '^[a-f0-9]{64}$'),
 bytes bigint not null check(bytes between 0 and 8388608), created_at timestamptz not null default now(),
 primary key(owner,digest)
);
alter table public.zeus_storage_meter enable row level security;
alter table public.zeus_storage_reservations enable row level security;
revoke all on public.zeus_storage_meter,public.zeus_storage_reservations from public,anon,authenticated;
grant select,insert,update,delete on public.zeus_storage_meter,public.zeus_storage_reservations to service_role;
create policy zeus_storage_meter_no_client on public.zeus_storage_meter for all to anon,authenticated using(false) with check(false);
create policy zeus_storage_reservations_no_client on public.zeus_storage_reservations for all to anon,authenticated using(false) with check(false);
create function public.zeus_reserve_object(user_id uuid,object_sha text,object_bytes bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare global_bytes bigint; owner_bytes bigint; previous bigint;
begin
 if user_id is null or object_sha is null or object_sha !~ '^[a-f0-9]{64}$' or object_bytes not between 0 and 8388608 then
  raise sqlstate 'PT400' using message='invalid_object_reservation'; end if;
 select used_bytes into global_bytes from public.zeus_storage_meter where id=1 for update;
 select bytes into previous from public.zeus_storage_reservations where owner=user_id and digest=object_sha;
 select coalesce(sum(bytes),0) into owner_bytes from public.zeus_storage_reservations where owner=user_id;
 if found and previous is not null then
  if previous<>object_bytes then raise sqlstate 'PT409' using message='object_size_conflict'; end if;
 else
  if global_bytes+object_bytes>838860800 or owner_bytes+object_bytes>629145600 then
   raise sqlstate 'PT507' using message='storage_allowance_reached'; end if;
  insert into public.zeus_storage_reservations(owner,digest,bytes) values(user_id,object_sha,object_bytes);
  update public.zeus_storage_meter set used_bytes=used_bytes+object_bytes where id=1;
  owner_bytes := owner_bytes+object_bytes;
 end if;
 return jsonb_build_object('used',owner_bytes,'limit',629145600,'verified_reservation',true);
end $$;
create function public.zeus_storage_usage(user_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select jsonb_build_object('used',coalesce(sum(bytes),0),'limit',629145600,'objects',count(*))
 from public.zeus_storage_reservations where owner=user_id
$$;
revoke all on function public.zeus_reserve_object(uuid,text,bigint),public.zeus_storage_usage(uuid) from public,anon,authenticated;
grant execute on function public.zeus_reserve_object(uuid,text,bigint),public.zeus_storage_usage(uuid) to service_role;
