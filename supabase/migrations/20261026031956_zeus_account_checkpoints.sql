create table public.zeus_cloud_versions (
  user_id uuid not null references auth.users(id) on delete cascade,
  revision bigint not null check (revision > 0), operation_id uuid not null,
  manifest jsonb not null check (octet_length(manifest::text) <= 262144),
  created_at timestamptz not null default now(), primary key (user_id, revision), unique (user_id, operation_id)
);
create table public.zeus_cloud_heads (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null, operation_id uuid not null,
  manifest jsonb not null check (octet_length(manifest::text) <= 262144), updated_at timestamptz not null default now(),
  foreign key (user_id, revision) references public.zeus_cloud_versions(user_id, revision)
);
alter table public.zeus_cloud_versions enable row level security;
alter table public.zeus_cloud_heads enable row level security;
revoke all on public.zeus_cloud_versions, public.zeus_cloud_heads from anon, authenticated;
grant select, insert, delete on public.zeus_cloud_versions to authenticated;
grant select, insert, update on public.zeus_cloud_heads to authenticated;
create policy zeus_versions_read on public.zeus_cloud_versions for select to authenticated using ((select auth.uid()) = user_id);
create policy zeus_versions_insert on public.zeus_cloud_versions for insert to authenticated with check ((select auth.uid()) = user_id);
create policy zeus_versions_delete on public.zeus_cloud_versions for delete to authenticated using ((select auth.uid()) = user_id);
create policy zeus_heads_read on public.zeus_cloud_heads for select to authenticated using ((select auth.uid()) = user_id);
create policy zeus_heads_insert on public.zeus_cloud_heads for insert to authenticated with check ((select auth.uid()) = user_id);
create policy zeus_heads_update on public.zeus_cloud_heads for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- An invoker transaction: Supabase RLS remains in force throughout the commit.
create function public.zeus_commit_checkpoint(expected_revision bigint, operation_id uuid, snapshot jsonb)
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

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('zeus-private', 'zeus-private', false, 8388608, array['application/octet-stream']) on conflict (id) do nothing;
create policy zeus_objects_select on storage.objects for select to authenticated
  using (bucket_id = 'zeus-private' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy zeus_objects_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'zeus-private' and (storage.foldername(name))[1] = (select auth.uid())::text
    and (storage.foldername(name))[2] = 'objects' and array_length(storage.foldername(name), 1) = 2
    and storage.filename(name) ~ '^[0-9a-f]{64}$');
-- No UPDATE/upsert: a hash-addressed object is immutable.
create policy zeus_objects_delete on storage.objects for delete to authenticated
  using (bucket_id = 'zeus-private' and (storage.foldername(name))[1] = (select auth.uid())::text);
