-- MyLoom sharing: run this once in your Supabase project's SQL Editor.
--
-- It makes:
--   • a private bucket, myloom-shares, for shared recordings (each video is watched through a
--     link that stops working after 14 days);
--   • a short list of users allowed to share (just the MyLoom user), and storage rules so only
--     they can upload, see and delete videos, each in their own folder. Other users of the
--     project, including anyone who signs up, can't use the bucket;
--   • an hourly job that deletes videos older than 14 days, so they don't build up.
--
-- Before running it, make the MyLoom user (Authentication → Users → Add user), then fill in the
-- three values just below. The URL and secret key are under Project Settings → API (or API Keys).
-- The secret key stays inside your database, in Vault, and is used only by the hourly job.
-- It's safe to run this again, for example to change the key or add another user.

create temp table myloom_setup as select
  'https://YOUR-PROJECT.supabase.co'::text as project_url,  -- ← your Project URL
  'YOUR-SECRET-KEY'::text                  as secret_key,   -- ← your secret key (sb_secret_…) or service_role key
  'YOUR-MYLOOM-USER@EXAMPLE.COM'::text     as sharer_email; -- ← the email of the user you made for MyLoom

do $$
declare
  setup record;
begin
  select * into setup from myloom_setup;
  if setup.project_url like '%YOUR-PROJECT%' or setup.secret_key = 'YOUR-SECRET-KEY' or setup.sharer_email like 'YOUR-%' then
    raise exception 'Fill in your project URL, secret key and MyLoom user email at the top first.';
  end if;
  if not exists (select 1 from auth.users where email = lower(setup.sharer_email)) then
    raise exception 'No user with the email %. Add it under Authentication → Users first.', setup.sharer_email;
  end if;
  perform vault.update_secret(id, setup.project_url) from vault.secrets where name = 'myloom_project_url';
  if not exists (select 1 from vault.secrets where name = 'myloom_project_url') then
    perform vault.create_secret(setup.project_url, 'myloom_project_url', 'MyLoom: where the cleanup job sends deletes');
  end if;
  perform vault.update_secret(id, setup.secret_key) from vault.secrets where name = 'myloom_secret_key';
  if not exists (select 1 from vault.secrets where name = 'myloom_secret_key') then
    perform vault.create_secret(setup.secret_key, 'myloom_secret_key', 'MyLoom: lets the cleanup job delete expired videos');
  end if;
end $$;

-- 1. The bucket. Private, MP4 only, up to 1 GB a video (also raise Storage's global upload limit
--    to 1 GB under Project Settings → Storage; a 10-minute share is usually 200–250 MB).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('myloom-shares', 'myloom-shares', false, 1073741824, array['video/mp4'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 2. Who may share. Its own schema, which the public API can't reach.
create schema if not exists myloom;
create table if not exists myloom.sharers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table myloom.sharers enable row level security;
insert into myloom.sharers (user_id)
select id from auth.users where email = lower((select sharer_email from myloom_setup))
on conflict (user_id) do nothing;

-- Whether the signed-in user is on the list (used by the storage rules below).
create or replace function myloom.is_sharer()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from myloom.sharers where user_id = (select auth.uid()))
$$;
revoke all on function myloom.is_sharer() from public, anon;
grant usage on schema myloom to authenticated;
grant execute on function myloom.is_sharer() to authenticated;

-- 3. Rules: a sharer can upload, list, link to and delete only what's in their own folder (MyLoom
--    puts each video in a folder named after the user's id). Viewers need no sign-in: the link
--    itself carries permission, for 14 days.
drop policy if exists "MyLoom: upload own shares" on storage.objects;
create policy "MyLoom: upload own shares" on storage.objects for insert to authenticated
  with check (bucket_id = 'myloom-shares' and (storage.foldername(name))[1] = (select auth.uid()::text)
              and (select myloom.is_sharer()));

drop policy if exists "MyLoom: see own shares" on storage.objects;
create policy "MyLoom: see own shares" on storage.objects for select to authenticated
  using (bucket_id = 'myloom-shares' and (storage.foldername(name))[1] = (select auth.uid()::text)
         and (select myloom.is_sharer()));

drop policy if exists "MyLoom: delete own shares" on storage.objects;
create policy "MyLoom: delete own shares" on storage.objects for delete to authenticated
  using (bucket_id = 'myloom-shares' and (storage.foldername(name))[1] = (select auth.uid()::text)
         and (select myloom.is_sharer()));

-- 4. Deleting expired videos. Files have to be deleted through the Storage API (deleting rows
--    from storage.objects would leave the files behind), so the job calls it with pg_net, using
--    the secret key from Vault.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create or replace function myloom.delete_expired_shares()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  project_url text;
  secret_key text;
  headers jsonb;
  expired record;
  deleted integer := 0;
begin
  select decrypted_secret into project_url from vault.decrypted_secrets where name = 'myloom_project_url';
  select decrypted_secret into secret_key from vault.decrypted_secrets where name = 'myloom_secret_key';
  if project_url is null or secret_key is null then
    raise exception 'MyLoom: the project URL and secret key are missing from Vault; run setup.sql again.';
  end if;
  -- New secret keys (sb_secret_…) go in the apikey header; older service_role keys are also a bearer token.
  headers := jsonb_build_object('apikey', secret_key);
  if secret_key like 'eyJ%' then
    headers := headers || jsonb_build_object('Authorization', 'Bearer ' || secret_key);
  end if;
  for expired in
    select name from storage.objects
    where bucket_id = 'myloom-shares' and created_at < now() - interval '14 days'
    order by created_at
    limit 200
  loop
    perform net.http_delete(
      url := rtrim(project_url, '/') || '/storage/v1/object/myloom-shares/' || expired.name,
      headers := headers,
      timeout_milliseconds := 10000);
    deleted := deleted + 1;
  end loop;
  return deleted;
end $$;

revoke all on function myloom.delete_expired_shares() from public, anon, authenticated;

-- Every hour, at 17 minutes past.
select cron.unschedule(jobid) from cron.job where jobname = 'myloom-delete-expired-shares';
select cron.schedule('myloom-delete-expired-shares', '17 * * * *', 'select myloom.delete_expired_shares()');

drop table myloom_setup;
