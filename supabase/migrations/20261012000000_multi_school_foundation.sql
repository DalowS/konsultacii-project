-- =====================================================================
-- v3.0 / МНОГОУЧИЛИЩНА СИСТЕМА – ЧАСТ 1 от 3: основа и миграция на данните
-- Файл: 20261012000000_multi_school_foundation.sql
--
-- Какво прави (само добавя; НЕ изтрива и НЕ пренаписва данни):
--   1. Създава schools, school_email_domains, school_memberships, super_admins,
--      super_admin_context, school_invites (всички с RLS, без политики = затворени;
--      политиките идват в част 2).
--   2. Създава ПЪРВОНАЧАЛНО училище (фиксиран id ...0001) и му прикача ВСИЧКИ
--      съществуващи учители, класове, предмети с групи, консултации, настройки.
--   3. Първоначалното училище получава домейн paisii.info (текущата настройка).
--   4. Всеки съществуващ профил получава членство (admin -> admin, останалите -> teacher).
--      Супер администратор НЕ се назначава автоматично – вижте supabase/manual/grant_super_admin.sql.
--   5. Добавя school_id (NOT NULL след попълване), уникални (id, school_id) и съставни външни
--      ключове, така че консултация в училище А не може да сочи клас/учител от училище Б.
--   6. Заменя регистрацията по домейн: сървърна проверка в auth.users (trigger) -> училището
--      се определя от домейна (или покана); публичната регистрация е САМО роля 'teacher'.
--   7. Брой записи ПРЕДИ/СЛЕД се сравнява в самата миграция; при разлика – изключение и
--      автоматичен ОТКАТ на цялата транзакция (SQL Editor / supabase db push изпълняват файла
--      в една транзакция).
--
-- ВАЖНО: тази част НЕ сменя RLS политиките и RPC функциите на приложението (това е част 2).
-- Прилагайте трите файла един след друг: 20261012 -> 20261013 -> 20261014.
-- Идемпотентна: повторно пускане не дублира училището, домейна, членствата и не връща
-- изтрит домейн.
-- =====================================================================

begin;

-- ---------- 0. Снимка „ПРЕДИ“ -----------------------------------------
create table if not exists public.multi_school_audit (
  id         bigint generated always as identity primary key,
  run_id     uuid        not null,
  phase      text        not null check (phase in ('before', 'after')),
  table_name text        not null,
  row_count  bigint      not null,
  taken_at   timestamptz not null default now()
);
alter table public.multi_school_audit enable row level security;
revoke all on public.multi_school_audit from public, anon, authenticated;

do $$
declare v_run uuid := gen_random_uuid();
begin
  perform set_config('app.ms_run', v_run::text, false);   -- само за тази сесия
  insert into public.multi_school_audit (run_id, phase, table_name, row_count)
  select v_run, 'before', t.name, t.cnt
  from (
    select 'teachers' as name, count(*)::bigint as cnt from public.teachers
    union all select 'classes', count(*) from public.classes
    union all select 'consultations', count(*) from public.consultations
    union all select 'consultation_classes', count(*) from public.consultation_classes
    union all select 'group_subjects', count(*) from public.group_subjects
    union all select 'school_settings', count(*) from public.school_settings
    union all select 'auth.users', count(*) from auth.users
  ) t;
end $$;

-- ---------- 1. Таблици -------------------------------------------------
create table if not exists public.schools (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  status     text not null default 'active',
  settings   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,
  constraint schools_name_len check (char_length(btrim(name)) between 1 and 150),
  constraint schools_status   check (status in ('active', 'inactive'))
);
create unique index if not exists schools_name_uq on public.schools (lower(btrim(name)));

drop trigger if exists schools_set_updated_at on public.schools;
create trigger schools_set_updated_at before update on public.schools
  for each row execute function public.set_updated_at();

create table if not exists public.school_email_domains (
  id               bigint generated always as identity primary key,
  school_id        uuid not null references public.schools (id) on delete cascade,
  domain           text not null,
  allow_subdomains boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  created_by       uuid references auth.users (id) on delete set null,
  -- нормализиран ASCII домейн (малки букви, без @, без интервали); поне една точка
  constraint school_email_domains_fmt check (
    domain = lower(domain) and char_length(domain) <= 253
    and domain ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'),
  constraint school_email_domains_uq unique (school_id, domain)
);
create index if not exists school_email_domains_active_idx
  on public.school_email_domains (domain) where active;

create table if not exists public.school_memberships (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  school_id  uuid not null references public.schools (id) on delete restrict,
  role       text not null default 'teacher',
  status     text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,
  constraint school_memberships_role   check (role in ('admin', 'teacher')),
  constraint school_memberships_status check (status in ('active', 'inactive')),
  constraint school_memberships_uq unique (user_id, school_id)
);
-- един профил = най-много едно АКТИВНО училище (съвместимост с модела „един профил на auth user“)
create unique index if not exists school_memberships_one_active_uq
  on public.school_memberships (user_id) where status = 'active';
create index if not exists school_memberships_school_idx on public.school_memberships (school_id);

drop trigger if exists school_memberships_set_updated_at on public.school_memberships;
create trigger school_memberships_set_updated_at before update on public.school_memberships
  for each row execute function public.set_updated_at();

-- Глобална роля (отделна от училищните роли). Записва се САМО от SQL Editor / service роля.
create table if not exists public.super_admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,
  note       text
);

-- Кое училище „администрира“ супер админът в момента (сървърно състояние на сесията).
create table if not exists public.super_admin_context (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  school_id  uuid references public.schools (id) on delete cascade,
  updated_at timestamptz not null default now()
);

-- Покани: изрично свързване на имейл с училище (за неразрешими/двусмислени домейни).
create table if not exists public.school_invites (
  id         bigint generated always as identity primary key,
  school_id  uuid not null references public.schools (id) on delete cascade,
  email      text not null,
  role       text not null default 'teacher',
  status     text not null default 'pending',
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,
  used_by    uuid references auth.users (id) on delete set null,
  used_at    timestamptz,
  constraint school_invites_email  check (email = lower(btrim(email)) and email ~ '^[^@[:space:]]+@[^@[:space:]]+$'),
  constraint school_invites_role   check (role = 'teacher'),            -- покана никога не дава admin
  constraint school_invites_status check (status in ('pending', 'used', 'cancelled'))
);
create unique index if not exists school_invites_pending_uq
  on public.school_invites (school_id, email) where status = 'pending';

alter table public.schools              enable row level security;
alter table public.school_email_domains enable row level security;
alter table public.school_memberships   enable row level security;
alter table public.super_admins         enable row level security;
alter table public.super_admin_context  enable row level security;
alter table public.school_invites       enable row level security;
-- Супабейс дава по подразбиране права на anon/authenticated -> затваряме; част 2 дава точните.
revoke all on public.schools, public.school_email_domains, public.school_memberships,
              public.super_admins, public.super_admin_context, public.school_invites
  from public, anon, authenticated;

-- ---------- 2. Помощни функции (SECURITY DEFINER, фиксиран search_path) ---
create or replace function public.normalize_domain(p_domain text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select regexp_replace(lower(btrim(coalesce(p_domain, ''))), '^@+|\.+$', '', 'g')
$$;
revoke all on function public.normalize_domain(text) from public, anon;
grant execute on function public.normalize_domain(text) to authenticated;

create or replace function public.is_super_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.super_admins s where s.user_id = auth.uid());
$$;
revoke all on function public.is_super_admin() from public, anon;
grant execute on function public.is_super_admin() to authenticated;

-- Училището, в което заявката „работи“:
--   * супер админ: само избраното (super_admin_context); без избор = глобален изглед (null);
--   * останалите: единственото АКТИВНО членство в АКТИВНО училище; иначе NULL (достъпът е блокиран).
create or replace function public.current_school_id()
returns uuid
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v uuid;
begin
  if auth.uid() is null then return null; end if;
  if exists (select 1 from public.super_admins s where s.user_id = auth.uid()) then
    -- супер админ „работи“ само в ИЗРИЧНО избрано училище; без избор = глобален изглед (null)
    select c.school_id into v from public.super_admin_context c
     where c.user_id = auth.uid() and c.school_id is not null
       and exists (select 1 from public.schools s where s.id = c.school_id);
    return v;
  end if;
  select m.school_id into v
    from public.school_memberships m
    join public.schools s on s.id = m.school_id
   where m.user_id = auth.uid() and m.status = 'active' and s.status = 'active'
   limit 1;
  return v;
end;
$$;
revoke all on function public.current_school_id() from public, anon;
grant execute on function public.current_school_id() to authenticated;

-- Единственото училище, ако има точно едно (преходно: съвместимост на директни INSERT без school_id).
create or replace function public._only_school_id()
returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case when count(*) = 1 then (array_agg(id))[1] end from public.schools
$$;
revoke all on function public._only_school_id() from public, anon, authenticated;

-- Определя училището за имейл при регистрация. Покана > домейн. Точно съвпадение на домейна;
-- поддомейни – само при изрично allow_subdomains. reason: invite | domain | none | ambiguous | inactive | invalid
create or replace function public.resolve_registration_school(p_email text)
returns table (school_id uuid, reason text)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_domain text;
  v_ids uuid[];
  v_n int;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    return query select null::uuid, 'invalid'::text; return;
  end if;
  v_domain := split_part(v_email, '@', 2);

  select array_agg(distinct i.school_id) into v_ids
    from public.school_invites i join public.schools s on s.id = i.school_id
   where i.email = v_email and i.status = 'pending' and i.expires_at > now() and s.status = 'active';
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n = 1 then return query select v_ids[1], 'invite'::text; return; end if;
  if v_n > 1 then return query select null::uuid, 'ambiguous'::text; return; end if;

  select array_agg(distinct e.school_id) into v_ids
    from public.school_email_domains e join public.schools s on s.id = e.school_id
   where e.active and s.status = 'active'
     and (e.domain = v_domain
          or (e.allow_subdomains and right(v_domain, char_length(e.domain) + 1) = '.' || e.domain));
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n = 1 then return query select v_ids[1], 'domain'::text; return; end if;
  if v_n > 1 then return query select null::uuid, 'ambiguous'::text; return; end if;

  if exists (select 1 from public.school_email_domains e join public.schools s on s.id = e.school_id
              where e.active and s.status = 'inactive'
                and (e.domain = v_domain
                     or (e.allow_subdomains and right(v_domain, char_length(e.domain) + 1) = '.' || e.domain))) then
    return query select null::uuid, 'inactive'::text; return;
  end if;
  return query select null::uuid, 'none'::text;
end;
$$;
revoke all on function public.resolve_registration_school(text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.resolve_registration_school(text) to supabase_auth_admin;
  end if;
end $$;

-- ---------- 3. school_id колони (първо nullable) -------------------------
alter table public.teachers             add column if not exists school_id uuid;
alter table public.classes              add column if not exists school_id uuid;
alter table public.group_subjects       add column if not exists school_id uuid;
alter table public.consultations        add column if not exists school_id uuid;
alter table public.consultation_classes add column if not exists school_id uuid;
alter table public.school_settings      add column if not exists school_id uuid;

-- ---------- 4. Първоначално училище + попълване на съществуващите данни ----
do $$
declare
  v_school constant uuid := '00000000-0000-4000-8000-000000000001';
  v_name text;
begin
  if not exists (select 1 from public.schools where id = v_school) then
    select school_name into v_name from public.school_settings where id = 1;
    insert into public.schools (id, name, status, settings)
    values (v_school, coalesce(nullif(btrim(v_name), ''), 'Училище'), 'active',
            jsonb_build_object('initial_school', true));
    -- текущият разрешен домейн става домейн на първоначалното училище
    insert into public.school_email_domains (school_id, domain)
    values (v_school, 'paisii.info')
    on conflict (school_id, domain) do nothing;
  end if;

  update public.teachers      set school_id = v_school where school_id is null;
  update public.classes       set school_id = v_school where school_id is null;
  update public.group_subjects set school_id = v_school where school_id is null;
  update public.consultations set school_id = v_school where school_id is null;
  update public.school_settings set school_id = v_school where school_id is null;
  update public.consultation_classes cc
     set school_id = c.school_id
    from public.consultations c
   where cc.consultation_id = c.id and cc.school_id is null;

  -- членства (само за профили, които още нямат такова; admin остава admin)
  insert into public.school_memberships (user_id, school_id, role, status)
  select t.id, t.school_id, case when t.role = 'admin' then 'admin' else 'teacher' end, 'active'
    from public.teachers t
   where not exists (select 1 from public.school_memberships m where m.user_id = t.id);
end $$;

-- ---------- 5. Ограничения (след попълването) ---------------------------
do $$
declare t text; v_nulls bigint;
begin
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings'] loop
    execute format('select count(*) from public.%I where school_id is null', t) into v_nulls;
    if v_nulls > 0 then
      raise exception 'Миграцията е спряна: % реда в % без school_id.', v_nulls, t;
    end if;
    execute format('alter table public.%I alter column school_id set not null', t);
    if not exists (select 1 from pg_constraint where conrelid = format('public.%I', t)::regclass
                      and conname = t || '_school_fk') then
      execute format('alter table public.%I add constraint %I foreign key (school_id) references public.schools (id) on delete restrict',
                     t, t || '_school_fk');
    end if;
    execute format('create index if not exists %I on public.%I (school_id)', t || '_school_idx', t);
  end loop;
end $$;

-- (id, school_id) – основа за съставни външни ключове (забрана на връзки между училища)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'teachers_id_school_uq') then
    alter table public.teachers add constraint teachers_id_school_uq unique (id, school_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'classes_id_school_uq') then
    alter table public.classes add constraint classes_id_school_uq unique (id, school_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'consultations_id_school_uq') then
    alter table public.consultations add constraint consultations_id_school_uq unique (id, school_id);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'consultations_teacher_school_fk') then
    alter table public.consultations add constraint consultations_teacher_school_fk
      foreign key (teacher_id, school_id) references public.teachers (id, school_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'consultation_classes_consultation_school_fk') then
    alter table public.consultation_classes add constraint consultation_classes_consultation_school_fk
      foreign key (consultation_id, school_id) references public.consultations (id, school_id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'consultation_classes_class_school_fk') then
    alter table public.consultation_classes add constraint consultation_classes_class_school_fk
      foreign key (class_id, school_id) references public.classes (id, school_id);
  end if;
end $$;

-- Уникалности: от глобални -> по училище (имената на старите ограничения не се предполагат).
do $$
declare r record;
begin
  for r in
    select c.conname from pg_constraint c
     where c.conrelid = 'public.classes'::regclass and c.contype = 'u'
       and (select array_agg(a.attname::text order by a.attnum) from pg_attribute a
             where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = array['name']
  loop
    execute format('alter table public.classes drop constraint %I', r.conname);
  end loop;
  for r in
    select c.conname from pg_constraint c
     where c.conrelid = 'public.group_subjects'::regclass and c.contype = 'u'
       and (select array_agg(a.attname::text order by a.attnum) from pg_attribute a
             where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = array['subject']
  loop
    execute format('alter table public.group_subjects drop constraint %I', r.conname);
  end loop;
end $$;
drop index if exists public.group_subjects_subject_uq;
create unique index if not exists classes_school_name_uq on public.classes (school_id, name);
create unique index if not exists group_subjects_school_subject_uq
  on public.group_subjects (school_id, lower(btrim(subject)));

-- school_settings: от „един ред (id=1)“ -> един ред на училище
alter table public.school_settings drop constraint if exists school_settings_single_row;
create sequence if not exists public.school_settings_id_seq owned by public.school_settings.id;
select setval('public.school_settings_id_seq', greatest((select coalesce(max(id), 1) from public.school_settings), 1));
alter table public.school_settings alter column id set default nextval('public.school_settings_id_seq');
create unique index if not exists school_settings_school_uq on public.school_settings (school_id);

-- ---------- 6. school_id: автоматично попълване и неизменяемост -----------
create or replace function public._set_school_id()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.school_id is not null then return new; end if;
  if tg_table_name = 'consultations' then
    select t.school_id into new.school_id from public.teachers t where t.id = new.teacher_id;
  elsif tg_table_name = 'consultation_classes' then
    select c.school_id into new.school_id from public.consultations c where c.id = new.consultation_id;
  else   -- classes, group_subjects, school_settings, teachers
    new.school_id := coalesce(public.current_school_id(), public._only_school_id());
  end if;
  if new.school_id is null then
    raise exception 'Не може да се определи училище за записа.' using errcode = 'CS001';
  end if;
  return new;
end;
$$;
revoke all on function public._set_school_id() from public, anon, authenticated;

create or replace function public._school_id_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.school_id is distinct from old.school_id then
    raise exception 'Записът не може да бъде преместен в друго училище.' using errcode = 'CS001';
  end if;
  return new;
end;
$$;
revoke all on function public._school_id_immutable() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_set_school_id', t);
    execute format('create trigger %I before insert on public.%I for each row execute function public._set_school_id()',
                   t || '_set_school_id', t);
    execute format('drop trigger if exists %I on public.%I', t || '_school_immutable', t);
    execute format('create trigger %I before update on public.%I for each row execute function public._school_id_immutable()',
                   t || '_school_immutable', t);
  end loop;
end $$;

-- ---------- 7. Членство -> teachers (огледало на ролята) -----------------
-- teachers.role остава (съвместимост), но източникът на истината е school_memberships.
create or replace function public._sync_membership_to_teacher()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid;
begin
  select t.school_id into v_school from public.teachers t where t.id = new.user_id;
  if v_school is not null and v_school <> new.school_id then
    raise exception 'Потребителят принадлежи на друго училище и не може да бъде преместен.' using errcode = 'CS001';
  end if;
  if new.status = 'active' then
    perform set_config('app.internal_role_sync', '1', true);
    update public.teachers set role = new.role where id = new.user_id and role is distinct from new.role;
    perform set_config('app.internal_role_sync', '', true);
  end if;
  return new;
end;
$$;
revoke all on function public._sync_membership_to_teacher() from public, anon, authenticated;
drop trigger if exists school_memberships_sync on public.school_memberships;
create trigger school_memberships_sync
  after insert or update of role, status on public.school_memberships
  for each row execute function public._sync_membership_to_teacher();

-- ---------- 8. Регистрация по домейн (сървърна, в auth.users) -------------
create or replace function public.enforce_email_domain()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r record; v_school uuid;
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;
  select * into r from public.resolve_registration_school(new.email);
  if tg_op = 'UPDATE' then
    -- смяна на имейл: новият адрес трябва да води към СЪЩОТО училище (или потребителят е супер админ)
    select m.school_id into v_school from public.school_memberships m
     where m.user_id = new.id and m.status = 'active';
    if exists (select 1 from public.super_admins s where s.user_id = new.id) then return new; end if;
    if v_school is not null and r.school_id is not distinct from v_school then return new; end if;
    raise exception 'Новият имейл не принадлежи към разрешен домейн на вашето училище.' using errcode = 'CS001';
  end if;
  if r.reason in ('invite', 'domain') then return new; end if;
  raise exception '%', case r.reason
    when 'ambiguous' then 'Домейнът на имейла е свързан с повече от едно училище. Необходима е покана от администратор на училището.'
    when 'inactive'  then 'Училището за този домейн не е активно.'
    else 'Регистрацията е разрешена само с имейл от домейн, разрешен от училище.' end
    using errcode = 'CS001';
end;
$$;
revoke all on function public.enforce_email_domain() from public, anon, authenticated;
drop trigger if exists auth_users_email_domain on auth.users;
create trigger auth_users_email_domain
  before insert or update of email on auth.users
  for each row execute function public.enforce_email_domain();

-- Профил + членство при нов auth user. Ролята НИКОГА не идва от потребителя: винаги 'teacher'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_name text; r record;
begin
  select * into r from public.resolve_registration_school(new.email);
  if r.reason not in ('invite', 'domain') then
    raise exception 'Регистрацията е разрешена само с имейл от домейн, разрешен от училище.' using errcode = 'CS001';
  end if;
  v_name := nullif(btrim(coalesce(new.raw_user_meta_data->>'name', '')), '');
  v_name := coalesce(v_name, nullif(btrim(coalesce(new.email, '')), ''), 'Потребител');
  insert into public.teachers (id, name, role, school_id)
  values (new.id, left(v_name, 100), 'teacher', r.school_id)
  on conflict (id) do nothing;
  insert into public.school_memberships (user_id, school_id, role, status)
  values (new.id, r.school_id, 'teacher', 'active')
  on conflict (user_id, school_id) do nothing;
  if r.reason = 'invite' then
    update public.school_invites
       set status = 'used', used_by = new.id, used_at = now()
     where school_id = r.school_id and email = lower(btrim(new.email)) and status = 'pending';
  end if;
  return new;
end;
$$;
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- Не-задължителен Auth hook (Dashboard -> Authentication -> Hooks -> Before User Created)
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare r record;
begin
  select * into r from public.resolve_registration_school(event -> 'user' ->> 'email');
  if r.reason in ('invite', 'domain') then return '{}'::jsonb; end if;
  return jsonb_build_object('error', jsonb_build_object(
    'message', case r.reason
      when 'ambiguous' then 'Домейнът на имейла е свързан с повече от едно училище. Необходима е покана.'
      when 'inactive'  then 'Училището за този домейн не е активно.'
      else 'Регистрацията е разрешена само с имейл от домейн, разрешен от училище.' end,
    'http_code', 400));
end;
$$;
revoke all on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
  end if;
end $$;

-- ---------- 9. Проверка „СЛЕД“ (при разлика – изключение = откат) ---------
do $$
declare
  v_run uuid := coalesce(nullif(current_setting('app.ms_run', true), '')::uuid,
                         (select run_id from public.multi_school_audit where phase = 'before' order by id desc limit 1));
  r record; v_bad bigint; v_msg text := '';
begin
  insert into public.multi_school_audit (run_id, phase, table_name, row_count)
  select v_run, 'after', t.name, t.cnt
  from (
    select 'teachers' as name, count(*)::bigint as cnt from public.teachers
    union all select 'classes', count(*) from public.classes
    union all select 'consultations', count(*) from public.consultations
    union all select 'consultation_classes', count(*) from public.consultation_classes
    union all select 'group_subjects', count(*) from public.group_subjects
    union all select 'school_settings', count(*) from public.school_settings
    union all select 'auth.users', count(*) from auth.users
  ) t;

  for r in
    select b.table_name, b.row_count as n_before, a.row_count as n_after
      from public.multi_school_audit b
      join public.multi_school_audit a on a.run_id = b.run_id and a.table_name = b.table_name and a.phase = 'after'
     where b.run_id = v_run and b.phase = 'before' and b.row_count <> a.row_count
  loop
    v_msg := v_msg || format(' %s: преди %s, след %s;', r.table_name, r.n_before, r.n_after);
  end loop;
  if v_msg <> '' then
    raise exception 'ПРОВЕРКА НЕУСПЕШНА – броят записи се е променил:%', v_msg;
  end if;

  select count(*) into v_bad from public.consultation_classes cc
    join public.consultations c on c.id = cc.consultation_id
    join public.classes k on k.id = cc.class_id
   where cc.school_id <> c.school_id or cc.school_id <> k.school_id;
  if v_bad > 0 then raise exception 'ПРОВЕРКА НЕУСПЕШНА: % консултации/класове от различни училища.', v_bad; end if;

  select count(*) into v_bad from public.teachers t
   where not exists (select 1 from public.school_memberships m where m.user_id = t.id and m.school_id = t.school_id);
  if v_bad > 0 then raise exception 'ПРОВЕРКА НЕУСПЕШНА: % профила без членство.', v_bad; end if;

  raise notice 'Многоучилищна основа: проверката е успешна (run %). Вижте public.multi_school_audit.', v_run;
end $$;

commit;
