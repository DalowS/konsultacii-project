-- Локален стенд, който имитира минимума от Supabase (НЕ е реален Supabase).
create schema if not exists auth;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}', created_at timestamptz default now(), email_confirmed_at timestamptz default now(), banned_until timestamptz);
create or replace function auth.uid() returns uuid language sql stable as $$ select (nullif(current_setting('request.jwt.claims', true),'')::json->>'sub')::uuid $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
end $$;
grant usage on schema public, auth to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
do $$ begin if not exists (select 1 from pg_publication where pubname='supabase_realtime') then create publication supabase_realtime; end if; end $$;
-- базови таблици (създадени ръчно в Supabase преди първата миграция)
create table public.teachers(id uuid primary key references auth.users(id) on delete cascade, name text not null, role text not null default 'teacher' check (role in ('admin','teacher')), created_at timestamptz default now());
create table public.classes(id bigint generated always as identity primary key, name text unique not null);
create table public.consultations(id bigint generated always as identity primary key, teacher_id uuid not null references public.teachers(id) on delete cascade, day int not null, shift int not null, hour int not null, subject text not null, location text, created_at timestamptz default now(), updated_at timestamptz default now());
create table public.consultation_classes(consultation_id bigint references public.consultations(id) on delete cascade, class_id bigint references public.classes(id), primary key(consultation_id, class_id));
create table public.group_subjects(id bigint generated always as identity primary key, subject text unique not null, enabled boolean default true);
