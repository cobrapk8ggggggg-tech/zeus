-- Explicit denial documents the service-only intent for security advisors.
create policy zeus_runtime_grants_no_client_access on public.zeus_runtime_grants
for all to anon, authenticated using (false) with check (false);
