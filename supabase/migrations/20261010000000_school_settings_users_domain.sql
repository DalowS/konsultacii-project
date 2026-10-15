-- =====================================================================
-- v2.9: настройки на училището, списък с потребители за админ,
--       регистрация само с имейл @paisii.info (на ниво база/Auth).
-- Идемпотентна. НЕ променя consultations, consultation_classes, classes,
-- group_subjects, RPC save_consultation/_save_consultation, индексите и
-- политиките им (конфликтите са по ден + смяна + час; няма принудителна смяна по етап).
-- Без service_role; всичко е SECURITY DEFINER с проверка is_admin() в самата функция.
-- =====================================================================

-- ---------- 1. Настройки на училището (един ред) -----------------------
create table if not exists public.school_settings (
  id            int primary key default 1,
  school_name   text not null,
  academic_year text not null,
  current_term  text not null,
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users (id) on delete set null,
  constraint school_settings_single_row check (id = 1),
  constraint school_settings_name_len   check (char_length(btrim(school_name)) between 1 and 150),
  constraint school_settings_term       check (current_term in ('I', 'II')),
  constraint school_settings_year_fmt   check (
    academic_year ~ '^[0-9]{4}/[0-9]{4}$'
    and case when academic_year ~ '^[0-9]{4}/[0-9]{4}$'
             then substr(academic_year, 6, 4)::int = substr(academic_year, 1, 4)::int + 1
             else false end)
);

insert into public.school_settings (id, school_name, academic_year, current_term)
values (1, 'СУ „Св. Паисий Хилендарски“ – Пловдив', '2026/2027', 'I')
on conflict (id) do nothing;

alter table public.school_settings enable row level security;

drop policy if exists school_settings_select on public.school_settings;
create policy school_settings_select on public.school_settings
  for select to authenticated using (true);
-- Умишлено НЯМА INSERT/UPDATE/DELETE политики: записът е само през admin_update_school_settings().

revoke all on public.school_settings from public, anon;
revoke insert, update, delete, truncate, trigger, references on public.school_settings from authenticated;
grant select on public.school_settings to authenticated;

create or replace function public.admin_update_school_settings(
  p_school_name text, p_academic_year text, p_current_term text
) returns public.school_settings
language plpgsql security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_school_name, ''));
  v_year text := btrim(coalesce(p_academic_year, ''));
  v_term text := upper(btrim(coalesce(p_current_term, '')));
  v_row  public.school_settings;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Само администратор може да променя настройките.' using errcode = 'CS001';
  end if;
  if char_length(v_name) not between 1 and 150 then
    raise exception 'Въведете име на училището (до 150 символа).' using errcode = 'CS001';
  end if;
  if v_year !~ '^[0-9]{4}/[0-9]{4}$' or substr(v_year, 6, 4)::int <> substr(v_year, 1, 4)::int + 1 then
    raise exception 'Учебната година трябва да е във формат 2026/2027 (последователни години).' using errcode = 'CS001';
  end if;
  if v_term not in ('I', 'II') then
    raise exception 'Срокът трябва да е I или II.' using errcode = 'CS001';
  end if;

  insert into public.school_settings (id, school_name, academic_year, current_term, updated_at, updated_by)
  values (1, v_name, v_year, v_term, now(), auth.uid())
  on conflict (id) do update
    set school_name = excluded.school_name, academic_year = excluded.academic_year,
        current_term = excluded.current_term, updated_at = now(), updated_by = auth.uid()
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.admin_update_school_settings(text, text, text) from public, anon;
grant execute on function public.admin_update_school_settings(text, text, text) to authenticated;

-- ---------- 2. Потребители (име, имейл, роля, статус, дата) – само админ -
-- Имейлът е в auth.users (недостъпна за клиента) -> четем през SECURITY DEFINER, без service_role.
create or replace function public.admin_list_users()
returns table (id uuid, name text, email text, role text, status text, created_at timestamptz)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Само администратор може да вижда потребителите.' using errcode = 'CS001';
  end if;
  return query
    select t.id, t.name, u.email::text, t.role,
           case when u.banned_until is not null and u.banned_until > now() then 'blocked'
                when u.email_confirmed_at is null then 'pending'
                else 'active' end,
           u.created_at
      from public.teachers t
      left join auth.users u on u.id = t.id
     order by t.name;
end;
$$;
revoke all on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;

-- ---------- 3. Регистрация само с @paisii.info -------------------------
-- Trigger върху auth.users: действа за ВСЕКИ начин на създаване (signUp, админ API, OAuth)
-- и при смяна на имейл. Съществуващите акаунти не се засягат, докато имейлът им не се променя.
create or replace function public.enforce_email_domain()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;
  if new.email is null or lower(btrim(new.email)) !~ '^[^@[:space:]]+@paisii\.info$' then
    raise exception 'Регистрацията е разрешена само с имейл от домейна @paisii.info.' using errcode = 'CS001';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_email_domain() from public, anon, authenticated;

drop trigger if exists auth_users_email_domain on auth.users;
create trigger auth_users_email_domain
  before insert or update of email on auth.users
  for each row execute function public.enforce_email_domain();

-- По желание (Dashboard -> Authentication -> Hooks -> "Before User Created" -> тази функция):
-- връща ясна грешка още преди създаването. Триггерът по-горе остава последна защита.
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare v_email text := lower(btrim(coalesce(event -> 'user' ->> 'email', '')));
begin
  if v_email !~ '^[^@[:space:]]+@paisii\.info$' then
    return jsonb_build_object('error', jsonb_build_object(
      'message', 'Регистрацията е разрешена само с имейл от домейна @paisii.info.',
      'http_code', 400));
  end if;
  return '{}'::jsonb;
end;
$$;
revoke all on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
  end if;
end $$;
