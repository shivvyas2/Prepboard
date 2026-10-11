-- Job sync: roles found in Gmail / LinkedIn by the Mac app's sync, plus the recruiter and what happened when.
alter table public.pb_roles
  add column if not exists recruiter       text not null default '',
  add column if not exists recruiter_email text not null default '',
  add column if not exists source          text not null default '',   -- '' (added by hand) | 'gmail' | 'linkedin'
  add column if not exists applied_at      timestamptz,
  add column if not exists activity        text not null default '';   -- Markdown lines: "- 2026-10-09 · Gmail · Recruiter reached out"
