-- Serialize release with the preparation transaction, including cancellation.
do $$ declare source text; needle text := 'if command=''gc_end'' then delete'; begin
 source := pg_get_functiondef('public.zeus_runtime_command(text,jsonb)'::regprocedure);
 if position(needle in source)=0 then raise exception 'Unexpected runtime function; lease release not changed'; end if;
 execute replace(source,needle,'if command=''gc_end'' then perform pg_advisory_xact_lock(hashtext(''zeus_checkpoint''),hashtext(u::text)); delete');
end $$;
