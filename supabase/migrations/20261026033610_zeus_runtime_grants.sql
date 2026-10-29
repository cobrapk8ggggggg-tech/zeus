-- Opaque, expiring storage capabilities. Only the authenticated Edge gateway
-- can issue/read them; neither the mobile app nor Railway gets an admin key.
create table public.zeus_runtime_grants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null references auth.sessions(id) on delete cascade,
  conversation_id uuid not null,
  token_sha256 text not null unique check (token_sha256 ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (expires_at <= created_at + interval '24 hours')
);
create index zeus_runtime_grants_owner on public.zeus_runtime_grants(user_id, conversation_id);
create index zeus_runtime_grants_expiry on public.zeus_runtime_grants(expires_at);
alter table public.zeus_runtime_grants enable row level security;
revoke all on public.zeus_runtime_grants from public, anon, authenticated;
grant select, insert, delete on public.zeus_runtime_grants to service_role;
