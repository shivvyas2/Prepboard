-- Prepboard "bring your own Anthropic key".
-- The key is encrypted by the prep-chat Edge Function (AES-GCM, secret PB_KEY_SECRET) before it is stored.
-- RLS is enabled with NO policies: clients can never read or write this table directly;
-- only the Edge Function (service role) touches it. Clients see status via the function (has key + last 4).

create table if not exists public.pb_ai_settings (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  anthropic_key_enc  text not null,
  key_hint           text not null default '',
  updated_at         timestamptz not null default now()
);

alter table public.pb_ai_settings enable row level security;
revoke all on public.pb_ai_settings from anon, authenticated;
