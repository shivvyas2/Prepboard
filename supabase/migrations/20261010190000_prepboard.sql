-- Prepboard: account-based storage for profiles, jobs (roles), prep sessions and documents.
-- Every row belongs to one auth user; Row Level Security restricts all access to the owner.
-- Ids are generated on the client (so the same seed ids can exist for different users),
-- which is why primary keys are (user_id, id).

-- ---------- profiles ----------
create table if not exists public.pb_profiles (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  name        text not null default '',
  headline    text not null default '',
  avatar      int  not null default 0,
  photo       text not null default '',          -- small (≤256px) JPEG data URL, empty when using an illustrated avatar
  updated_at  timestamptz not null default now()
);

-- ---------- jobs / roles ----------
create table if not exists public.pb_roles (
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id             text not null,
  company        text not null default '',
  title          text not null default '',
  team           text not null default '',
  location       text not null default '',
  role_number    text not null default '',
  salary         text not null default '',
  link           text not null default '',
  stage          text not null default 'Saved'
                 check (stage in ('Saved','Applied','Recruiter','Technical','Onsite','Offer','Closed')),
  interview_at   timestamptz,
  interview_note text not null default '',
  notes          text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (user_id, id)
);

-- ---------- documents ----------
create table if not exists public.pb_docs (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id          text not null,
  role_id     text not null default '',            -- '' = General
  title       text not null default '',
  body        text not null default '',
  tags        text[] not null default '{}',
  sort_order  int  not null default 999,
  updated_at  timestamptz not null default now(),
  primary key (user_id, id)
);

-- ---------- prep sessions (timeline) ----------
create table if not exists public.pb_sessions (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id          text not null,
  role_id     text not null default '',
  title       text not null default '',
  start_at    timestamptz not null,
  end_at      timestamptz not null,
  kind        text not null default 'study'
              check (kind in ('study','practice','mock','review','logistics','break')),
  refs        jsonb not null default '[]',         -- [{ "doc": "<doc id>", "heading": "<## heading or ''>" }]
  done        boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (user_id, id),
  check (end_at > start_at)
);

create index if not exists pb_sessions_user_start on public.pb_sessions (user_id, start_at);
create index if not exists pb_docs_user_role on public.pb_docs (user_id, role_id);

-- ---------- row level security: owner-only ----------
alter table public.pb_profiles enable row level security;
alter table public.pb_roles    enable row level security;
alter table public.pb_docs     enable row level security;
alter table public.pb_sessions enable row level security;

do $$
declare t text;
begin
  foreach t in array array['pb_profiles','pb_roles','pb_docs','pb_sessions'] loop
    execute format('drop policy if exists "owner select" on public.%I', t);
    execute format('drop policy if exists "owner insert" on public.%I', t);
    execute format('drop policy if exists "owner update" on public.%I', t);
    execute format('drop policy if exists "owner delete" on public.%I', t);
    execute format('create policy "owner select" on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
    execute format('create policy "owner insert" on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)', t);
    execute format('create policy "owner update" on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t);
    execute format('create policy "owner delete" on public.%I for delete to authenticated using ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- ---------- create a profile row automatically on sign-up ----------
create or replace function public.pb_handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.pb_profiles (user_id, name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'name', ''))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists pb_on_auth_user_created on auth.users;
create trigger pb_on_auth_user_created
  after insert on auth.users
  for each row execute function public.pb_handle_new_user();
