-- Job hunt: jobs the Mac app discovers (leads), the user's hunt settings and answer bank, and which
-- resume variant was sent with each role (so Technical / Onsite / Offer can mark it a winner).

alter table public.pb_roles
  add column if not exists resume_variant text not null default '';   -- .tex file name without extension, e.g. "Shiv-Vyas-Apple-ScreenSharing-SDE"

-- ---------- leads: one discovered job, reviewed on any device, submitted by the Mac ----------
create table if not exists public.pb_leads (
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id               text not null,
  company          text not null default '',
  title            text not null default '',
  location         text not null default '',
  link             text not null default '',
  role_number      text not null default '',       -- posting id if visible
  source           text not null default '',       -- 'linkedin-rec' | 'linkedin-search' | 'careers'
  jd               text not null default '',       -- full job description text
  score            int  not null default 0,        -- 0-100 match
  score_reason     text not null default '',
  status           text not null default 'new'
                   check (status in ('new','tailoring','ready','needs_you','submitting','submitted','skipped','failed')),
  base_variant     text not null default '',       -- base .tex the variant was tailored from
  base_reason      text not null default '',
  variant_name     text not null default '',       -- generated .tex (no extension)
  pdf_doc_id       text not null default '',       -- pb_docs id of the built PDF
  coverage         jsonb not null default '[]',    -- [{ "term": "", "covered": true }]
  answers          jsonb not null default '[]',    -- [{ "question": "", "answer": "", "kind": "bank|drafted|needs_you", "required": true }]
  flagged          text not null default '',       -- newline-separated questions / blocks that need the user
  reason           text not null default '',       -- last status reason or error
  role_id          text not null default '',       -- pb_roles id created on submit
  submit_requested boolean not null default false, -- set from any device; the Mac submits
  found_at         timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (user_id, id)
);

create index if not exists pb_leads_user_found on public.pb_leads (user_id, found_at desc);

-- ---------- hunt settings: one row per user ----------
create table if not exists public.pb_hunt_settings (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  regions            text[] not null default '{}',   -- "United States", "United States / New York"
  companies          text[] not null default '{}',   -- "Apple" or "Apple | https://jobs.apple.com/..."
  keywords           text[] not null default '{}',   -- "iOS Engineer", "Full Stack"
  auto               boolean not null default false, -- daily run on/off
  run_hour           int  not null default 8,        -- 0-23, local time on the Mac
  min_score          int  not null default 60,
  daily_tailor_limit int  not null default 30,
  daily_submit_limit int  not null default 30,
  resume_folder      text not null default '',       -- Mac path; only the Mac writes it
  answers            jsonb not null default '{}',    -- AnswerBank: contact, work authorization, EEO, saved free-text answers
  updated_at         timestamptz not null default now()
);

-- ---------- row level security: owner-only ----------
alter table public.pb_leads         enable row level security;
alter table public.pb_hunt_settings enable row level security;

do $$
declare t text;
begin
  foreach t in array array['pb_leads','pb_hunt_settings'] loop
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
