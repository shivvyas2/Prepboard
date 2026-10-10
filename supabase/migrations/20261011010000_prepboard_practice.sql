-- Prepboard practice: LeetCode/CoderPad-style coding problems with the user's code per language.

create table if not exists public.pb_problems (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id          text not null,
  role_id     text not null default '',
  title       text not null default '',
  difficulty  text not null default 'Medium',   -- Easy | Medium | Hard
  topics      text[] not null default '{}',
  statement   text not null default '',          -- Markdown: description, examples, constraints
  starters    jsonb not null default '{}',       -- { "swift": "...", "python": "...", "javascript": "..." } incl. test harness
  code        jsonb not null default '{}',       -- the user's code per language
  language    text not null default 'swift',
  solved      boolean not null default false,
  notes       text not null default '',          -- AI review / the user's notes
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (user_id, id)
);

alter table public.pb_problems enable row level security;
drop policy if exists "owner select" on public.pb_problems;
drop policy if exists "owner insert" on public.pb_problems;
drop policy if exists "owner update" on public.pb_problems;
drop policy if exists "owner delete" on public.pb_problems;
create policy "owner select" on public.pb_problems for select to authenticated using ((select auth.uid()) = user_id);
create policy "owner insert" on public.pb_problems for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "owner update" on public.pb_problems for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "owner delete" on public.pb_problems for delete to authenticated using ((select auth.uid()) = user_id);
