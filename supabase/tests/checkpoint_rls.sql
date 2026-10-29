begin;
select set_config('zeus.test.a', gen_random_uuid()::text, true), set_config('zeus.test.b', gen_random_uuid()::text, true);
insert into auth.users(id, aud, role) values
 (current_setting('zeus.test.a')::uuid, 'authenticated', 'authenticated'),
 (current_setting('zeus.test.b')::uuid, 'authenticated', 'authenticated');
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', current_setting('zeus.test.a'), 'role', 'authenticated')::text, true);
do $test$
declare op uuid := gen_random_uuid(); result jsonb; denied boolean := false;
  doc jsonb := jsonb_build_object('version',1,'browser',jsonb_build_object('sha256',repeat('a',64),'bytes',10));
begin
  result := public.zeus_commit_checkpoint(0,op,doc);
  if result->>'revision' <> '1' then raise exception 'first revision incorrect'; end if;
  if public.zeus_commit_checkpoint(0,op,doc) <> result then raise exception 'idempotency failed'; end if;
  begin perform public.zeus_commit_checkpoint(0,gen_random_uuid(),doc);
    exception when sqlstate 'PT409' then denied := true; end;
  if not denied then raise exception 'stale update accepted'; end if;
  denied := false;
  begin insert into public.zeus_cloud_versions(user_id,revision,operation_id,manifest)
    values (current_setting('zeus.test.b')::uuid,1,gen_random_uuid(),doc);
    exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'cross owner write accepted'; end if;
  denied := false;
  begin update public.zeus_cloud_heads set user_id=current_setting('zeus.test.b')::uuid;
    exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'ownership reassignment accepted'; end if;
  denied := false;
  begin perform public.zeus_commit_checkpoint(1,gen_random_uuid(),jsonb_build_object('browser',doc->'browser'));
    exception when sqlstate 'PT400' then denied := true; end;
  if not denied then raise exception 'invalid manifest accepted'; end if;
end $test$;
select set_config('request.jwt.claims', jsonb_build_object('sub', current_setting('zeus.test.b'), 'role', 'authenticated')::text, true);
do $test$
begin
 if exists(select 1 from public.zeus_cloud_heads) then raise exception 'cross owner read accepted'; end if;
end $test$;
select jsonb_build_object('owner_isolation',true,'compare_and_swap',true,'idempotency',true,'manifest_validation',true) as checks;
rollback;
