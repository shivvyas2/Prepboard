-- Practice: YouTube explanations saved per problem.
alter table public.pb_problems
  add column if not exists videos jsonb not null default '[]';   -- [{ "id": "<youtube id>", "title": "", "channel": "", "why": "" }]
