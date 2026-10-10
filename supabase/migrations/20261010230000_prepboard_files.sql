-- Prepboard files: PDF documents stored in a private bucket, one folder per user (<user id>/<doc id>.pdf).

alter table public.pb_docs
  add column if not exists file_type text not null default 'md' check (file_type in ('md', 'pdf')),
  add column if not exists file_path text not null default '';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pb-files', 'pb-files', false, 26214400, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 26214400, allowed_mime_types = array['application/pdf'];

drop policy if exists "pb files owner select" on storage.objects;
drop policy if exists "pb files owner insert" on storage.objects;
drop policy if exists "pb files owner update" on storage.objects;
drop policy if exists "pb files owner delete" on storage.objects;

create policy "pb files owner select" on storage.objects for select to authenticated
  using (bucket_id = 'pb-files' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "pb files owner insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'pb-files' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "pb files owner update" on storage.objects for update to authenticated
  using (bucket_id = 'pb-files' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'pb-files' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "pb files owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'pb-files' and (storage.foldername(name))[1] = (select auth.uid())::text);
