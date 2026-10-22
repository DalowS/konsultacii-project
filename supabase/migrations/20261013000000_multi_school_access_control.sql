-- =====================================================================
-- v3.0 / МНОГОУЧИЛИЩНА СИСТЕМА – ЧАСТ 2 от 3: роли, RLS, RPC
-- Файл: 20261013000000_multi_school_access_control.sql
-- Предполага вече приложена 20261012000000_multi_school_foundation.sql
-- (данните са мигрирани и проверени; чак сега се сменят политиките – „новата RLS“).
--
-- Роли:
--   super_admin  – глобална роля (public.super_admins); вижда/управлява всички училища;
--                  „работи“ в избрано училище (set_active_school).
--   admin        – училищна роля (school_memberships.role); само собственото училище.
--   teacher      – училищна роля; собственото училище, собствените консултации.
-- Всички записи в защитените таблици минават през SECURITY DEFINER RPC с проверки на сървъра.
-- Клиентът НИКОГА не подава school_id/teacher_id/роля, на които сървърът да вярва.
-- Идемпотентна.
-- =====================================================================

begin;

-- ---------- 1. Помощни функции ------------------------------------------
-- admin = училищен админ на ТЕКУЩОТО училище или супер админ с избрано училище
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.current_school_id() is not null and (
    exists (select 1 from public.super_admins s where s.user_id = auth.uid())
    or exists (select 1 from public.school_memberships m
                where m.user_id = auth.uid() and m.status = 'active' and m.role = 'admin'
                  and m.school_id = public.current_school_id()));
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- админ на конкретно училище (супер админ – на всяко)
create or replace function public.is_school_admin(p_school uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_school is not null and auth.uid() is not null and (
    exists (select 1 from public.super_admins s where s.user_id = auth.uid())
    or exists (select 1 from public.school_memberships m join public.schools sc on sc.id = m.school_id
                where m.user_id = auth.uid() and m.status = 'active' and m.role = 'admin'
                  and m.school_id = p_school and sc.status = 'active'));
$$;
revoke all on function public.is_school_admin(uuid) from public, anon;
grant execute on function public.is_school_admin(uuid) to authenticated;

-- Училище на админ операция: текущото; иначе грешка. (Параметър от клиента не се приема за вярно.)
create or replace function public._admin_school()
returns uuid
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v uuid := public.current_school_id();
begin
  if auth.uid() is null or v is null or not public.is_admin() then
    raise exception 'Само администратор може да изпълни тази операция.' using errcode = 'CS001';
  end if;
  return v;
end;
$$;
revoke all on function public._admin_school() from public, anon, authenticated;

-- Целево училище за операции с домейни/покани: супер админ – подаденото; школски админ – само своето.
create or replace function public._target_school(p_school uuid)
returns uuid
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_cur uuid := public.current_school_id(); v_target uuid;
begin
  if auth.uid() is null then
    raise exception 'Не сте влезли в системата.' using errcode = 'CS001';
  end if;
  v_target := coalesce(p_school, v_cur);
  if v_target is null then
    raise exception 'Не е избрано училище.' using errcode = 'CS001';
  end if;
  if public.is_super_admin() then
    if not exists (select 1 from public.schools s where s.id = v_target) then
      raise exception 'Училището не е намерено.' using errcode = 'CS001';
    end if;
    return v_target;
  end if;
  if v_target is distinct from v_cur or not public.is_admin() then
    raise exception 'Нямате право на тази операция.' using errcode = 'CS001';
  end if;
  return v_target;
end;
$$;
revoke all on function public._target_school(uuid) from public, anon, authenticated;

-- Слотът (смяна, час) валиден ли е за училището? (част 3 го заменя с проверка по интервалите)
create or replace function public._slot_valid(p_school uuid, p_shift int, p_hour int)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select p_shift between 1 and 2 and p_hour between 1 and 7 $$;
revoke all on function public._slot_valid(uuid, int, int) from public, anon, authenticated;

-- ---------- 2. Защита на teachers ---------------------------------------
-- Роля/училище не се сменят с директен UPDATE – само през RPC (вътрешен флаг).
create or replace function public.teachers_protect_role()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'Идентификаторът не може да се променя.' using errcode = 'CS001';
  end if;
  if new.school_id is distinct from old.school_id then
    raise exception 'Потребителят не може да бъде преместен в друго училище.' using errcode = 'CS001';
  end if;
  if new.role is distinct from old.role
     and coalesce(current_setting('app.internal_role_sync', true), '') <> '1' then
    raise exception 'Ролите се променят само от администратор през „Потребители“.' using errcode = 'CS001';
  end if;
  return new;
end;
$$;
revoke all on function public.teachers_protect_role() from public, anon, authenticated;
drop trigger if exists teachers_protect_role on public.teachers;
create trigger teachers_protect_role
  before update on public.teachers
  for each row execute function public.teachers_protect_role();

-- ---------- 3. RLS политики ---------------------------------------------
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname from pg_policies
     where schemaname = 'public'
       and tablename in ('teachers','classes','group_subjects','consultations','consultation_classes',
                         'school_settings','schools','school_email_domains','school_memberships',
                         'super_admins','super_admin_context','school_invites')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- Данни на училището: достъп само до текущото училище (блокирано при неактивно училище/без членство)
create policy teachers_select on public.teachers
  for select to authenticated using (id = auth.uid() or school_id = public.current_school_id());
create policy teachers_update_own on public.teachers
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy teachers_update_admin on public.teachers
  for update to authenticated
  using (public.is_admin() and school_id = public.current_school_id())
  with check (public.is_admin() and school_id = public.current_school_id());

create policy classes_select on public.classes
  for select to authenticated using (school_id = public.current_school_id());
create policy classes_delete_admin on public.classes
  for delete to authenticated using (public.is_admin() and school_id = public.current_school_id());

create policy group_subjects_select on public.group_subjects
  for select to authenticated using (school_id = public.current_school_id());

create policy consultations_select on public.consultations
  for select to authenticated using (school_id = public.current_school_id());
create policy consultations_delete on public.consultations
  for delete to authenticated
  using (school_id = public.current_school_id() and (teacher_id = auth.uid() or public.is_admin()));

create policy consultation_classes_select on public.consultation_classes
  for select to authenticated using (school_id = public.current_school_id());

create policy school_settings_select on public.school_settings
  for select to authenticated using (school_id = public.current_school_id());

-- Управление на училища
create policy schools_select on public.schools
  for select to authenticated
  using (public.is_super_admin()
         or id = public.current_school_id()
         or exists (select 1 from public.school_memberships m where m.user_id = auth.uid() and m.school_id = schools.id));
create policy school_email_domains_select on public.school_email_domains
  for select to authenticated
  using (public.is_super_admin() or (school_id = public.current_school_id() and public.is_admin()));
create policy school_memberships_select on public.school_memberships
  for select to authenticated
  using (user_id = auth.uid() or public.is_super_admin()
         or (school_id = public.current_school_id() and public.is_admin()));
create policy school_invites_select on public.school_invites
  for select to authenticated
  using (public.is_super_admin() or (school_id = public.current_school_id() and public.is_admin()));
create policy super_admins_select on public.super_admins
  for select to authenticated using (user_id = auth.uid());
-- super_admin_context: без политики (достъп само през RPC)

-- GRANT-ове: минималните (defence in depth, RLS не филтрира TRUNCATE и т.н.)
revoke all on public.teachers, public.classes, public.group_subjects, public.consultations,
              public.consultation_classes, public.school_settings, public.schools,
              public.school_email_domains, public.school_memberships, public.super_admins,
              public.super_admin_context, public.school_invites
  from anon;
revoke all on public.schools, public.school_email_domains, public.school_memberships, public.super_admins,
              public.super_admin_context, public.school_invites from authenticated;
grant select on public.schools, public.school_email_domains, public.school_memberships,
                public.super_admins, public.school_invites to authenticated;

revoke insert, delete, truncate, trigger, references on public.teachers from authenticated;
revoke update on public.teachers from authenticated;
grant update (name) on public.teachers to authenticated;            -- роля/училище не се пишат директно

revoke insert, update, truncate, trigger, references on public.classes from authenticated;
revoke insert, update, delete, truncate, trigger, references on public.group_subjects from authenticated;
revoke insert, update, delete, truncate, trigger, references on public.school_settings from authenticated;
revoke insert, update, truncate, trigger, references on public.consultations from authenticated;
revoke insert, update, delete, truncate, trigger, references on public.consultation_classes from authenticated;

-- ---------- 4. Контекст и профил ----------------------------------------
create or replace function public.get_my_context()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_super boolean;
  v_cur uuid;
  v_name text; v_email text;
  v_mem record;
  v_school record;
begin
  if v_uid is null then
    raise exception 'Не сте влезли в системата.' using errcode = 'CS001';
  end if;
  v_super := exists (select 1 from public.super_admins s where s.user_id = v_uid);
  select t.name into v_name from public.teachers t where t.id = v_uid;
  select u.email::text into v_email from auth.users u where u.id = v_uid;
  v_cur := public.current_school_id();
  select null::uuid as id, null::text as name, null::text as status into v_school;

  select m.school_id, m.role, m.status into v_mem
    from public.school_memberships m
   where m.user_id = v_uid and m.status = 'active' limit 1;

  if v_cur is not null then
    select s.id, s.name, s.status into v_school from public.schools s where s.id = v_cur;
  elsif v_mem.school_id is not null and not v_super then
    -- супер админ без избрано училище = глобален изглед (school = null)
    select s.id, s.name, s.status into v_school from public.schools s where s.id = v_mem.school_id;
  end if;

  return jsonb_build_object(
    'user_id', v_uid,
    'name', coalesce(v_name, v_email, 'Потребител'),
    'email', v_email,
    'is_super_admin', v_super,
    'membership_role', v_mem.role,
    'is_admin', public.is_admin(),
    'role', case when v_super then 'super_admin' when public.is_admin() then 'admin'
                 when v_cur is not null then 'teacher' else null end,
    'school', case when v_school.id is null then null
                   else jsonb_build_object('id', v_school.id, 'name', v_school.name, 'status', v_school.status) end,
    'blocked', (v_cur is null and not v_super),
    'blocked_reason', case when v_cur is not null or v_super then null
                           when v_mem.school_id is null then 'no_membership'
                           when v_school.status = 'inactive' then 'school_inactive'
                           else 'unknown' end
  );
end;
$$;
revoke all on function public.get_my_context() from public, anon;
grant execute on function public.get_my_context() to authenticated;

create or replace function public.set_active_school(p_school uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school record;
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да избира училище.' using errcode = 'CS001';
  end if;
  if p_school is null then
    delete from public.super_admin_context where user_id = auth.uid();
    return null;
  end if;
  select s.id, s.name, s.status into v_school from public.schools s where s.id = p_school;
  if not found then
    raise exception 'Училището не е намерено.' using errcode = 'CS001';
  end if;
  insert into public.super_admin_context (user_id, school_id, updated_at)
  values (auth.uid(), p_school, now())
  on conflict (user_id) do update set school_id = excluded.school_id, updated_at = now();
  return jsonb_build_object('id', v_school.id, 'name', v_school.name, 'status', v_school.status);
end;
$$;
revoke all on function public.set_active_school(uuid) from public, anon;
grant execute on function public.set_active_school(uuid) to authenticated;

-- ---------- 5. Супер администратор: училища ------------------------------
create or replace function public.super_list_schools()
returns table (id uuid, name text, status text, created_at timestamptz,
               teachers_count bigint, admins_count bigint, classes_count bigint,
               consultations_count bigint, domains text[])
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да вижда всички училища.' using errcode = 'CS001';
  end if;
  return query
    select s.id, s.name, s.status, s.created_at,
           (select count(*) from public.teachers t where t.school_id = s.id),
           (select count(*) from public.school_memberships m
             where m.school_id = s.id and m.role = 'admin' and m.status = 'active'),
           (select count(*) from public.classes k where k.school_id = s.id),
           (select count(*) from public.consultations c where c.school_id = s.id),
           coalesce((select array_agg(d.domain order by d.domain) from public.school_email_domains d
                      where d.school_id = s.id and d.active), '{}')
      from public.schools s
     order by lower(s.name);
end;
$$;
revoke all on function public.super_list_schools() from public, anon;
grant execute on function public.super_list_schools() to authenticated;

create or replace function public._default_academic_year()
returns text
language sql stable
set search_path = public, pg_temp
as $$
  select case when extract(month from now()) >= 9
              then extract(year from now())::int || '/' || (extract(year from now())::int + 1)
              else (extract(year from now())::int - 1) || '/' || extract(year from now())::int end
$$;
revoke all on function public._default_academic_year() from public, anon, authenticated;

create or replace function public.super_create_school(p_name text, p_domain text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
  v_domain text := public.normalize_domain(p_domain);
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да създава училища.' using errcode = 'CS001';
  end if;
  if char_length(v_name) not between 1 and 150 then
    raise exception 'Въведете име на училището (до 150 символа).' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.schools s where lower(btrim(s.name)) = lower(v_name)) then
    raise exception 'Вече има училище с това име.' using errcode = 'CS001';
  end if;
  insert into public.schools (name, status, created_by) values (v_name, 'active', auth.uid())
  returning schools.id into v_id;
  insert into public.school_settings (school_id, school_name, academic_year, current_term)
  values (v_id, v_name, public._default_academic_year(), 'I');
  if v_domain <> '' then
    perform public.admin_add_domain(v_domain, false, v_id);
  end if;
  return v_id;
end;
$$;
revoke all on function public.super_create_school(text, text) from public, anon;
grant execute on function public.super_create_school(text, text) to authenticated;

create or replace function public.super_update_school(p_id uuid, p_name text, p_status text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_name text := btrim(coalesce(p_name, ''));
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да променя училища.' using errcode = 'CS001';
  end if;
  if char_length(v_name) not between 1 and 150 then
    raise exception 'Въведете име на училището (до 150 символа).' using errcode = 'CS001';
  end if;
  if p_status not in ('active', 'inactive') then
    raise exception 'Невалиден статус.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.schools s where lower(btrim(s.name)) = lower(v_name) and s.id <> p_id) then
    raise exception 'Вече има училище с това име.' using errcode = 'CS001';
  end if;
  update public.schools set name = v_name, status = p_status where id = p_id;
  if not found then
    raise exception 'Училището не е намерено.' using errcode = 'CS001';
  end if;
  update public.school_settings set school_name = v_name, updated_at = now(), updated_by = auth.uid()
   where school_id = p_id;
end;
$$;
revoke all on function public.super_update_school(uuid, text, text) from public, anon;
grant execute on function public.super_update_school(uuid, text, text) to authenticated;

-- ---------- 6. Домейни ---------------------------------------------------
-- Публични пощенски домейни: могат да се добавят само от супер администратор.
create or replace function public._is_public_mail_domain(p_domain text)
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select p_domain = any (array['gmail.com','googlemail.com','abv.bg','mail.bg','dir.bg','gbg.bg','yahoo.com',
    'outlook.com','hotmail.com','live.com','msn.com','icloud.com','me.com','aol.com','proton.me',
    'protonmail.com','mail.com','gmx.com','yandex.com','yandex.ru','mail.ru','zoho.com'])
$$;
revoke all on function public._is_public_mail_domain(text) from public, anon, authenticated;

create or replace function public.admin_list_domains(p_school uuid default null)
returns table (id bigint, school_id uuid, domain text, allow_subdomains boolean, active boolean,
               created_at timestamptz, conflict_count bigint, conflict_names text[])
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public._target_school(p_school); v_super boolean := public.is_super_admin();
begin
  return query
    select d.id, d.school_id, d.domain, d.allow_subdomains, d.active, d.created_at,
           (select count(*) from public.school_email_domains o join public.schools os on os.id = o.school_id
             where o.domain = d.domain and o.active and os.status = 'active' and o.school_id <> d.school_id),
           case when v_super then
             (select array_agg(os.name order by os.name) from public.school_email_domains o
                join public.schools os on os.id = o.school_id
               where o.domain = d.domain and o.active and os.status = 'active' and o.school_id <> d.school_id)
           else null end
      from public.school_email_domains d
     where d.school_id = v_school
     order by d.domain;
end;
$$;
revoke all on function public.admin_list_domains(uuid) from public, anon;
grant execute on function public.admin_list_domains(uuid) to authenticated;

create or replace function public.admin_add_domain(p_domain text, p_allow_subdomains boolean default false,
                                                   p_school uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._target_school(p_school);
  v_domain text := public.normalize_domain(p_domain);
  v_id bigint; v_conflicts int;
begin
  if char_length(v_domain) > 253 or v_domain !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' then
    raise exception 'Невалиден домейн. Пример: school.example.bg (само латински букви, цифри, тире и точки).' using errcode = 'CS001';
  end if;
  select count(*) into v_conflicts from public.school_email_domains o join public.schools os on os.id = o.school_id
   where o.domain = v_domain and o.active and os.status = 'active' and o.school_id <> v_school;
  if not public.is_super_admin() then
    if public._is_public_mail_domain(v_domain) then
      raise exception 'Публични пощенски домейни не могат да бъдат разрешавани за регистрация.' using errcode = 'CS001';
    end if;
    if v_conflicts > 0 then
      raise exception 'Домейнът вече се използва от друго училище. Обърнете се към супер администратор.' using errcode = 'CS001';
    end if;
  end if;
  if exists (select 1 from public.school_email_domains where school_id = v_school and domain = v_domain) then
    raise exception 'Домейнът вече е добавен към това училище.' using errcode = 'CS001';
  end if;
  insert into public.school_email_domains (school_id, domain, allow_subdomains, created_by)
  values (v_school, v_domain, coalesce(p_allow_subdomains, false), auth.uid())
  returning school_email_domains.id into v_id;
  return jsonb_build_object('id', v_id, 'domain', v_domain, 'conflict_count', v_conflicts);
end;
$$;
revoke all on function public.admin_add_domain(text, boolean, uuid) from public, anon;
grant execute on function public.admin_add_domain(text, boolean, uuid) to authenticated;

create or replace function public.admin_update_domain(p_id bigint, p_active boolean, p_allow_subdomains boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_row public.school_email_domains; v_conflicts int;
begin
  select * into v_row from public.school_email_domains where id = p_id;
  if not found then raise exception 'Домейнът не е намерен.' using errcode = 'CS001'; end if;
  perform public._target_school(v_row.school_id);
  select count(*) into v_conflicts from public.school_email_domains o join public.schools os on os.id = o.school_id
   where o.domain = v_row.domain and o.active and os.status = 'active' and o.school_id <> v_row.school_id;
  if not public.is_super_admin() and coalesce(p_active, v_row.active) and not v_row.active and v_conflicts > 0 then
    raise exception 'Домейнът вече се използва от друго училище. Обърнете се към супер администратор.' using errcode = 'CS001';
  end if;
  update public.school_email_domains
     set active = coalesce(p_active, active), allow_subdomains = coalesce(p_allow_subdomains, allow_subdomains)
   where id = p_id;
  return jsonb_build_object('id', p_id, 'conflict_count', v_conflicts);
end;
$$;
revoke all on function public.admin_update_domain(bigint, boolean, boolean) from public, anon;
grant execute on function public.admin_update_domain(bigint, boolean, boolean) to authenticated;

create or replace function public.admin_remove_domain(p_id bigint)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid;
begin
  select school_id into v_school from public.school_email_domains where id = p_id;
  if not found then raise exception 'Домейнът не е намерен.' using errcode = 'CS001'; end if;
  perform public._target_school(v_school);
  delete from public.school_email_domains where id = p_id;      -- съществуващите акаунти не се засягат
end;
$$;
revoke all on function public.admin_remove_domain(bigint) from public, anon;
grant execute on function public.admin_remove_domain(bigint) to authenticated;

-- ---------- 7. Покани (изрично свързване на имейл с училище) --------------
create or replace function public.admin_invite_teacher(p_email text, p_school uuid default null)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._target_school(p_school);
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_id bigint;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(v_email) > 254 then
    raise exception 'Невалиден имейл адрес.' using errcode = 'CS001';
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception 'Този имейл вече е регистриран.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.school_invites i
              where i.email = v_email and i.status = 'pending' and i.expires_at > now() and i.school_id <> v_school) then
    raise exception 'За този имейл има покана от друго училище.' using errcode = 'CS001';
  end if;
  update public.school_invites set status = 'cancelled'
   where school_id = v_school and email = v_email and status = 'pending';
  insert into public.school_invites (school_id, email, role, created_by)
  values (v_school, v_email, 'teacher', auth.uid())
  returning school_invites.id into v_id;
  return v_id;
end;
$$;
revoke all on function public.admin_invite_teacher(text, uuid) from public, anon;
grant execute on function public.admin_invite_teacher(text, uuid) to authenticated;

create or replace function public.admin_cancel_invite(p_id bigint)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid;
begin
  select school_id into v_school from public.school_invites where id = p_id;
  if not found then raise exception 'Поканата не е намерена.' using errcode = 'CS001'; end if;
  perform public._target_school(v_school);
  update public.school_invites set status = 'cancelled' where id = p_id and status = 'pending';
end;
$$;
revoke all on function public.admin_cancel_invite(bigint) from public, anon;
grant execute on function public.admin_cancel_invite(bigint) to authenticated;

-- ---------- 8. Потребители и роли ----------------------------------------
create or replace function public.admin_list_users()
returns table (id uuid, name text, email text, role text, status text, created_at timestamptz)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public._admin_school();
begin
  return query
    select t.id, t.name, u.email::text, coalesce(m.role, 'teacher')::text,
           (case when m.status is distinct from 'active' then 'blocked'
                 when u.banned_until is not null and u.banned_until > now() then 'blocked'
                 when u.email_confirmed_at is null then 'pending'
                 else 'active' end)::text,
           u.created_at
      from public.teachers t
      left join public.school_memberships m on m.user_id = t.id and m.school_id = t.school_id
      left join auth.users u on u.id = t.id
     where t.school_id = v_school
     order by t.name;
end;
$$;
revoke all on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;

-- Смяна на училищна роля (admin/teacher) в ТЕКУЩОТО училище. Супер админ не се създава оттук.
create or replace function public.admin_set_member_role(p_user uuid, p_role text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public._admin_school(); v_old text;
begin
  if p_role not in ('admin', 'teacher') then
    raise exception 'Невалидна роля.' using errcode = 'CS001';
  end if;
  if p_user = auth.uid() then
    raise exception 'Не можете да променяте собствената си роля.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.super_admins s where s.user_id = p_user) then
    raise exception 'Ролята на супер администратор не се променя оттук.' using errcode = 'CS001';
  end if;
  select m.role into v_old from public.school_memberships m
   where m.user_id = p_user and m.school_id = v_school and m.status = 'active' for update;
  if not found then
    raise exception 'Потребителят не е член на това училище.' using errcode = 'CS001';
  end if;
  if v_old = 'admin' and p_role = 'teacher' and not exists (
       select 1 from public.school_memberships m
        where m.school_id = v_school and m.role = 'admin' and m.status = 'active' and m.user_id <> p_user) then
    raise exception 'Не може да бъде премахнат последният администратор на училището.' using errcode = 'CS001';
  end if;
  update public.school_memberships set role = p_role where user_id = p_user and school_id = v_school;
end;
$$;
revoke all on function public.admin_set_member_role(uuid, text) from public, anon;
grant execute on function public.admin_set_member_role(uuid, text) to authenticated;

-- Супер админ: назначава/сваля училищен админ по имейл (потребителят вече трябва да е регистриран в това училище)
create or replace function public.super_set_school_admin(p_school uuid, p_email text, p_admin boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_user uuid; v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да назначава администратори на училища.' using errcode = 'CS001';
  end if;
  select u.id into v_user from auth.users u where lower(u.email) = v_email;
  if v_user is null then
    raise exception 'Няма регистриран потребител с този имейл. Първо трябва да се регистрира.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.super_admins s where s.user_id = v_user) then
    raise exception 'Ролята на супер администратор не се променя оттук.' using errcode = 'CS001';
  end if;
  perform 1 from public.school_memberships m
   where m.user_id = v_user and m.school_id = p_school and m.status = 'active' for update;
  if not found then
    raise exception 'Потребителят не е член на това училище.' using errcode = 'CS001';
  end if;
  update public.school_memberships set role = case when p_admin then 'admin' else 'teacher' end
   where user_id = v_user and school_id = p_school;
end;
$$;
revoke all on function public.super_set_school_admin(uuid, text, boolean) from public, anon;
grant execute on function public.super_set_school_admin(uuid, text, boolean) to authenticated;

create or replace function public.super_list_school_admins(p_school uuid)
returns table (user_id uuid, name text, email text, status text)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да вижда администраторите на училища.' using errcode = 'CS001';
  end if;
  return query
    select m.user_id, t.name, u.email::text, m.status::text
      from public.school_memberships m
      left join public.teachers t on t.id = m.user_id
      left join auth.users u on u.id = m.user_id
     where m.school_id = p_school and m.role = 'admin'
     order by t.name;
end;
$$;
revoke all on function public.super_list_school_admins(uuid) from public, anon;
grant execute on function public.super_list_school_admins(uuid) to authenticated;

-- Премахване на учител (Auth акаунт + консултации в една транзакция), само в текущото училище.
create or replace function public.admin_delete_teacher(p_teacher uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_role text; v_n int;
begin
  if p_teacher is null then
    raise exception 'Невалиден потребител.' using errcode = 'CS001';
  end if;
  if p_teacher = auth.uid() then
    raise exception 'Не можете да премахнете собствения си акаунт.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.super_admins s where s.user_id = p_teacher) then
    raise exception 'Супер администратор не може да бъде премахнат оттук.' using errcode = 'CS001';
  end if;
  select m.role into v_role from public.school_memberships m
   where m.user_id = p_teacher and m.school_id = v_school for update;
  if not found or not exists (select 1 from public.teachers t where t.id = p_teacher and t.school_id = v_school) then
    raise exception 'Учителят не е намерен.' using errcode = 'CS001';
  end if;
  if v_role = 'admin' and not exists (
       select 1 from public.school_memberships m
        where m.school_id = v_school and m.role = 'admin' and m.status = 'active' and m.user_id <> p_teacher) then
    raise exception 'Не може да бъде премахнат последният администратор.' using errcode = 'CS001';
  end if;

  delete from public.consultations where teacher_id = p_teacher and school_id = v_school;
  get diagnostics v_n = row_count;
  delete from auth.users where id = p_teacher;       -- каскадно: teachers, school_memberships
  if exists (select 1 from public.teachers where id = p_teacher) then
    raise exception 'Неуспешно премахване на акаунта.' using errcode = 'CS001';
  end if;
  return jsonb_build_object('consultations_deleted', v_n);
end;
$$;
revoke all on function public.admin_delete_teacher(uuid) from public, anon;
grant execute on function public.admin_delete_teacher(uuid) to authenticated;

-- ---------- 9. Настройки на училището ------------------------------------
create or replace function public.admin_update_school_settings(
  p_school_name text, p_academic_year text, p_current_term text
) returns public.school_settings
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_name text := btrim(coalesce(p_school_name, ''));
  v_year text := btrim(coalesce(p_academic_year, ''));
  v_term text := upper(btrim(coalesce(p_current_term, '')));
  v_row  public.school_settings;
begin
  if char_length(v_name) not between 1 and 150 then
    raise exception 'Въведете име на училището (до 150 символа).' using errcode = 'CS001';
  end if;
  if v_year !~ '^[0-9]{4}/[0-9]{4}$' or substr(v_year, 6, 4)::int <> substr(v_year, 1, 4)::int + 1 then
    raise exception 'Учебната година трябва да е във формат 2026/2027 (последователни години).' using errcode = 'CS001';
  end if;
  if v_term not in ('I', 'II') then
    raise exception 'Срокът трябва да е I или II.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.schools s where lower(btrim(s.name)) = lower(v_name) and s.id <> v_school) then
    raise exception 'Вече има училище с това име.' using errcode = 'CS001';
  end if;

  update public.schools set name = v_name where id = v_school;
  insert into public.school_settings (school_id, school_name, academic_year, current_term, updated_at, updated_by)
  values (v_school, v_name, v_year, v_term, now(), auth.uid())
  on conflict (school_id) do update
    set school_name = excluded.school_name, academic_year = excluded.academic_year,
        current_term = excluded.current_term, updated_at = now(), updated_by = auth.uid()
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.admin_update_school_settings(text, text, text) from public, anon;
grant execute on function public.admin_update_school_settings(text, text, text) to authenticated;

-- ---------- 10. Класове и предмети с групи --------------------------------
create or replace function public.admin_add_class(p_grade int, p_letter text)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_letter text := translate(btrim(coalesce(p_letter, '')), 'ABEKMHOPCTX', 'АВЕКМНОРСТХ');
  v_name   text;
  v_id     bigint;
begin
  if p_grade is null or p_grade not between 5 and 12 then
    raise exception 'Номерът на класа трябва да е от 5 до 12.' using errcode = 'CS001';
  end if;
  if v_letter !~ '^[А-Я]$' then
    raise exception 'Паралелката трябва да е една главна буква (А-Я).' using errcode = 'CS001';
  end if;
  v_name := p_grade::text || v_letter;

  perform pg_advisory_xact_lock(hashtext('classes_admin:' || v_school::text));
  if exists (select 1 from public.classes k
              where k.school_id = v_school and translate(k.name, 'ABEKMHOPCTX', 'АВЕКМНОРСТХ') = v_name) then
    raise exception 'Класът % вече съществува.', v_name using errcode = 'CS001';
  end if;
  insert into public.classes (name, school_id) values (v_name, v_school) returning classes.id into v_id;
  return v_id;
end;
$$;
revoke all on function public.admin_add_class(int, text) from public, anon;
grant execute on function public.admin_add_class(int, text) to authenticated;

create or replace function public.admin_set_group_subject(p_subject text, p_enabled boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public._admin_school(); v_subject text := btrim(coalesce(p_subject, ''));
begin
  if char_length(v_subject) not between 1 and 100 then
    raise exception 'Въведете предмет (до 100 символа).' using errcode = 'CS001';
  end if;
  update public.group_subjects set enabled = coalesce(p_enabled, true)
   where school_id = v_school and lower(btrim(subject)) = lower(v_subject);
  if not found then
    insert into public.group_subjects (subject, enabled, school_id)
    values (v_subject, coalesce(p_enabled, true), v_school);
  end if;
end;
$$;
revoke all on function public.admin_set_group_subject(text, boolean) from public, anon;
grant execute on function public.admin_set_group_subject(text, boolean) to authenticated;

-- ---------- 11. Консултации ---------------------------------------------
create or replace function public._save_consultation(
  p_id bigint, p_teacher uuid, p_day int, p_shift int, p_hour int,
  p_subject text, p_location text, p_classes text[]
) returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school    uuid;
  v_subject   text := btrim(coalesce(p_subject, ''));
  v_location  text := nullif(btrim(coalesce(p_location, '')), '');
  v_class_ids bigint[];
  v_cid       bigint;
  v_cname     text;
  v_is_group  boolean;
  v_n         int;
  v_same_subj boolean;
  v_same_loc  boolean;
  v_id        bigint;
begin
  select t.school_id into v_school from public.teachers t where t.id = p_teacher;
  if v_school is null then
    raise exception 'Учителят не е намерен.' using errcode = 'CS001';
  end if;
  if p_id is not null and not exists (select 1 from public.consultations c where c.id = p_id and c.school_id = v_school) then
    raise exception 'Записът не е намерен.' using errcode = 'CS001';
  end if;

  if p_day not between 1 and 5 or not public._slot_valid(v_school, p_shift, p_hour) then
    raise exception 'Невалиден ден, смяна или час.' using errcode = 'CS001';
  end if;
  if v_subject = '' or char_length(v_subject) > 100 then
    raise exception 'Моля, въведете предмет (до 100 символа).' using errcode = 'CS001';
  end if;
  if v_location is not null and char_length(v_location) > 100 then
    raise exception 'Мястото е твърде дълго (до 100 символа).' using errcode = 'CS001';
  end if;

  -- класовете се търсят САМО в училището на учителя (клас от друго училище = „невалиден избор“)
  select array_agg(c.id) into v_class_ids from public.classes c
   where c.school_id = v_school and c.name = any (p_classes);
  if coalesce(cardinality(v_class_ids), 0) = 0
     or cardinality(v_class_ids) <> (select count(distinct x) from unnest(p_classes) x) then
    raise exception 'Невалиден избор на клас.' using errcode = 'CS001';
  end if;

  -- Слотът е (училище, ден, смяна, час); сериализира конкурентни записи.
  perform pg_advisory_xact_lock(hashtext('consultation_slot:' || v_school::text),
                                p_day * 100 + p_shift * 10 + p_hour);

  if exists (select 1 from public.consultations c
             where c.teacher_id = p_teacher and c.day = p_day
               and c.shift = p_shift and c.hour = p_hour
               and (p_id is null or c.id <> p_id)) then
    raise exception 'Учителят вече има друга консултация в този час.' using errcode = 'CS001';
  end if;

  v_is_group := exists (select 1 from public.group_subjects g
                        where g.school_id = v_school and g.enabled and lower(btrim(g.subject)) = lower(v_subject));
  if v_is_group and v_location is null then
    raise exception 'При предмет с паралелни групи трябва да бъде посочено място.' using errcode = 'CS001';
  end if;

  foreach v_cid in array v_class_ids loop
    select count(*),
           coalesce(bool_and(lower(btrim(o.subject)) = lower(v_subject)), true),
           coalesce(bool_or(v_location is not null
                            and lower(btrim(coalesce(o.location, ''))) = lower(v_location)), false)
      into v_n, v_same_subj, v_same_loc
      from public.consultations o
      join public.consultation_classes oc on oc.consultation_id = o.id
     where oc.class_id = v_cid and o.day = p_day and o.shift = p_shift and o.hour = p_hour
       and (p_id is null or o.id <> p_id);

    if v_n > 0 then
      select name into v_cname from public.classes where id = v_cid;
      if not v_is_group or not v_same_subj then
        raise exception 'Клас % вече има консултация в този час.', v_cname using errcode = 'CS001';
      elsif v_n >= 2 then
        raise exception 'Клас %: вече има две групи в този час.', v_cname using errcode = 'CS001';
      elsif v_same_loc then
        raise exception 'При паралелни групи местата трябва да са различни.' using errcode = 'CS001';
      end if;
    end if;
  end loop;

  if p_id is null then
    insert into public.consultations (teacher_id, day, shift, hour, subject, location, school_id)
    values (p_teacher, p_day, p_shift, p_hour, v_subject, v_location, v_school)
    returning id into v_id;
  else
    update public.consultations
       set day = p_day, shift = p_shift, hour = p_hour,
           subject = v_subject, location = v_location
     where id = p_id;
    v_id := p_id;
    delete from public.consultation_classes
     where consultation_id = v_id and class_id <> all (v_class_ids);
  end if;

  insert into public.consultation_classes (consultation_id, class_id, school_id)
  select v_id, x, v_school from unnest(v_class_ids) x
  on conflict do nothing;

  return v_id;
end;
$$;
revoke all on function public._save_consultation(bigint, uuid, int, int, int, text, text, text[])
  from public, anon, authenticated;

create or replace function public.save_consultation(
  p_id bigint, p_day int, p_shift int, p_hour int,
  p_subject text, p_location text, p_classes text[]
) returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public.current_school_id(); v_teacher uuid; v_owner_school uuid;
begin
  if auth.uid() is null then
    raise exception 'Не сте влезли в системата.' using errcode = 'CS001';
  end if;
  if v_school is null then
    raise exception 'Нямате достъп до активно училище.' using errcode = 'CS001';
  end if;
  if p_id is null then
    v_teacher := auth.uid();
    select t.school_id into v_owner_school from public.teachers t where t.id = v_teacher;
    if v_owner_school is distinct from v_school then
      raise exception 'Нямате профил на учител в това училище.' using errcode = 'CS001';
    end if;
  else
    select c.teacher_id into v_teacher from public.consultations c
     where c.id = p_id and c.school_id = v_school for update;
    if not found then
      raise exception 'Записът не е намерен.' using errcode = 'CS001';
    end if;
    if v_teacher <> auth.uid() and not public.is_admin() then
      raise exception 'Нямате право да редактирате този запис.' using errcode = 'CS001';
    end if;
  end if;
  return public._save_consultation(p_id, v_teacher, p_day, p_shift, p_hour, p_subject, p_location, p_classes);
end;
$$;
revoke all on function public.save_consultation(bigint, int, int, int, text, text, text[]) from public, anon;
grant execute on function public.save_consultation(bigint, int, int, int, text, text, text[]) to authenticated;

create or replace function public.admin_clear_consultations()
returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public._admin_school(); v_n integer;
begin
  with d as (delete from public.consultations where school_id = v_school returning 1)
  select count(*) into v_n from d;
  return v_n;
end;
$$;
revoke all on function public.admin_clear_consultations() from public, anon;
grant execute on function public.admin_clear_consultations() to authenticated;

create or replace function public.import_consultations(p_items jsonb, p_replace boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_item jsonb; v_idx int := 0; v_teacher uuid; v_name text;
  v_imported int := 0; v_dups int := 0; v_errors jsonb := '[]'::jsonb;
  v_classes text[]; v_day int; v_shift int; v_hour int; v_subject text;
begin
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Невалиден формат на данните.' using errcode = 'CS001';
  end if;
  if p_replace then delete from public.consultations where school_id = v_school; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_idx := v_idx + 1;
    begin
      v_teacher := null;
      if (v_item->>'teacherId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        select id into v_teacher from public.teachers
         where id = (v_item->>'teacherId')::uuid and school_id = v_school;
      end if;
      v_name := btrim(coalesce(v_item->>'teacherName', ''));
      if v_teacher is null and v_name <> '' then
        select id into v_teacher from public.teachers
         where school_id = v_school and lower(btrim(name)) = lower(v_name)
         limit 1;
      end if;
      if v_teacher is null then
        raise exception 'Не е намерен учител „%“ (регистрирайте го и повторете).', v_name using errcode = 'CS001';
      end if;

      v_day := (v_item->>'day')::int; v_shift := (v_item->>'shift')::int; v_hour := (v_item->>'hour')::int;
      v_subject := btrim(coalesce(v_item->>'subject', ''));
      select coalesce(array_agg(x), '{}') into v_classes
        from jsonb_array_elements_text(coalesce(v_item->'classes', '[]'::jsonb)) x;

      if exists (select 1 from public.consultations c
                 where c.teacher_id = v_teacher and c.day = v_day
                   and c.shift = v_shift and c.hour = v_hour
                   and lower(btrim(c.subject)) = lower(v_subject)) then
        v_dups := v_dups + 1;
      else
        perform public._save_consultation(null, v_teacher, v_day, v_shift, v_hour,
                                          v_subject, v_item->>'location', v_classes);
        v_imported := v_imported + 1;
      end if;
    exception when others then
      v_errors := v_errors || jsonb_build_object('index', v_idx, 'message', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('imported', v_imported, 'duplicates', v_dups, 'errors', v_errors);
end;
$$;
revoke all on function public.import_consultations(jsonb, boolean) from public, anon;
grant execute on function public.import_consultations(jsonb, boolean) to authenticated;

-- ---------- 12. Realtime за новите, четими от клиента таблици --------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['school_settings'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

commit;
