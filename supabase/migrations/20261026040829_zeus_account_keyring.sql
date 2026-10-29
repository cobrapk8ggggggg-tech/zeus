-- Per-account encryption keys survive device deletion and password recovery.
-- They are never returned by the gateway and are separate from Storage blobs.
create table public.zeus_account_keyring (
  user_id uuid primary key references auth.users(id) on delete cascade,
  key_b64 text not null,
  version integer not null default 1 check (version = 1),
  created_at timestamptz not null default now()
);
alter table public.zeus_account_keyring enable row level security;
revoke all on public.zeus_account_keyring from public, anon, authenticated;
grant select, insert on public.zeus_account_keyring to service_role;
create policy zeus_account_keyring_no_client_access on public.zeus_account_keyring
for all to anon, authenticated using (false) with check (false);
