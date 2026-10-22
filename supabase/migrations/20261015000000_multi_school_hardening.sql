-- =====================================================================
-- v3.0 / МНОГОУЧИЛИЩНА СИСТЕМА – ЧАСТ 4: твърдост преди първо пускане в реалния Supabase
-- Файл: 20261015000000_multi_school_hardening.sql
-- Предполага 20261012, 20261013 и 20261014. НЕ променя данни; НЕ променя старите миграции.
--
--   1. Базовите таблици (classes, group_subjects, …) са създадени ПРЕДИ миграциите в репото, затова не
--      знаем дали старата глобална уникалност върху classes(name) / group_subjects(subject) е „constraint“
--      или самостоятелен „unique index“ (с неизвестно име). 20261012 маха само constraint-и. Тук се махат
--      и останалите глобални уникални индекси БЕЗ school_id върху тези две таблици – иначе второ
--      училище не може да има клас „5А“ / същия предмет. Уникалността по училище (classes_school_name_uq,
--      group_subjects_school_subject_uq) остава и е единствената.
--   2. Realtime: графикът на часовете (school_schedule_settings, school_intervals) и училищата (schools,
--      напр. деактивиране) се публикуват, за да се виждат промените без презареждане (RLS пак филтрира).
--   4. ОДИТ: админ на училище А можеше да добави „родителски“ домейн с поддомейни (напр. example.bg), който
--      припокрива домейна на училище Б (school-b.example.bg) и прави регистрацията на Б „двусмислена“ (отказ).
--      Проверката за конфликт беше само за ТОЧНО съвпадение. Сега за админ на училище (не супер админ)
--      се отказва всяко припокриване между активни домейни на различни училища – точно, като поддомейн или
--      като родителски домейн с allow_subdomains. Супер админът може (и вижда предупреждение).
--   5. ОДИТ: покана от училище А за имейл с домейн, който е разрешен САМО за училище Б, би „откраднала“ бъдещата
--      регистрация на Б (поканата има предимство пред домейна). Админ на училище вече не може да кани такъв
--      имейл; позволени са външни имейли и имейли от домейн, споделен и с неговото училище. Супер админът не е ограничен.
--   3. Тригер функциите classes_protect_delete() и set_updated_at() нямат причина да са извикваеми
--      от клиента (EXECUTE се проверява при CREATE TRIGGER, не при задействане).
-- Идемпотентна.
-- =====================================================================

begin;

-- ---------- 1. Глобални уникални индекси върху classes / group_subjects ----------
do $$
declare r record;
begin
  -- 1а. constraint-и (дропването им премахва и индекса)
  for r in
    select c.conrelid::regclass::text as tbl, c.conname
      from pg_constraint c
     where c.conrelid in ('public.classes'::regclass, 'public.group_subjects'::regclass)
       and c.contype = 'u'
       and pg_get_constraintdef(c.oid) !~ 'school_id'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
    raise notice 'Премахнат глобален unique constraint % върху %', r.conname, r.tbl;
  end loop;

  -- 1б. самостоятелни уникални индекси (без първичния ключ и без тези със school_id)
  for r in
    select i.indrelid::regclass::text as tbl, ic.relname as idx
      from pg_index i
      join pg_class ic on ic.oid = i.indexrelid
     where i.indrelid in ('public.classes'::regclass, 'public.group_subjects'::regclass)
       and i.indisunique and not i.indisprimary
       and pg_get_indexdef(i.indexrelid) !~ 'school_id'
       and not exists (select 1 from pg_constraint c where c.conindid = i.indexrelid)
  loop
    execute format('drop index public.%I', r.idx);
    raise notice 'Премахнат глобален unique индекс % върху %', r.idx, r.tbl;
  end loop;
end $$;

-- уникалността по училище трябва да съществува (идемпотентно; създадена е и в 20261012)
create unique index if not exists classes_school_name_uq on public.classes (school_id, name);
create unique index if not exists group_subjects_school_subject_uq
  on public.group_subjects (school_id, lower(btrim(subject)));

-- ---------- 2. Realtime ------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime' and not puballtables) then
    foreach t in array array['school_schedule_settings', 'school_intervals', 'schools'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ---------- 3. Тригер функции: без EXECUTE за клиентските роли ----------------------
do $$
begin
  if to_regprocedure('public.classes_protect_delete()') is not null then
    revoke all on function public.classes_protect_delete() from public, anon, authenticated;
  end if;
  if to_regprocedure('public.set_updated_at()') is not null then
    revoke all on function public.set_updated_at() from public, anon, authenticated;
  end if;
end $$;

-- ---------- 4. Припокриване на домейни между училища --------------------------------
-- Брой и имена на ДРУГИ активни училища, чийто активен домейн води към същите имейли:
--   същият домейн | чужд домейн с allow_subdomains, който е родител на новия | нов домейн с allow_subdomains, който е родител на чужд.
create or replace function public._domain_overlaps(p_domain text, p_allow_sub boolean, p_school uuid, p_ignore_id bigint default null)
returns table (n bigint, names text[])
language sql stable security definer
set search_path = public, pg_temp
as $$
  select count(*), array_agg(distinct s.name order by s.name)
    from public.school_email_domains o
    join public.schools s on s.id = o.school_id
   where o.active and s.status = 'active' and o.school_id <> p_school
     and (p_ignore_id is null or o.id <> p_ignore_id)
     and (o.domain = p_domain
          or (o.allow_subdomains and right(p_domain, char_length(o.domain) + 1) = '.' || o.domain)
          or (coalesce(p_allow_sub, false) and right(o.domain, char_length(p_domain) + 1) = '.' || p_domain))
$$;
revoke all on function public._domain_overlaps(text, boolean, uuid, bigint) from public, anon, authenticated;

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
           case when d.active then x.n else 0 end,
           case when v_super and d.active then x.names else null end
      from public.school_email_domains d
      cross join lateral public._domain_overlaps(d.domain, d.allow_subdomains, d.school_id, d.id) x
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
  v_id bigint; v_conflicts bigint;
begin
  if char_length(v_domain) > 253 or v_domain !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' then
    raise exception 'Невалиден домейн. Пример: school.example.bg (само латински букви, цифри, тире и точки).' using errcode = 'CS001';
  end if;
  select x.n into v_conflicts from public._domain_overlaps(v_domain, coalesce(p_allow_subdomains, false), v_school) x;
  if not public.is_super_admin() then
    if public._is_public_mail_domain(v_domain) then
      raise exception 'Публични пощенски домейни не могат да бъдат разрешавани за регистрация.' using errcode = 'CS001';
    end if;
    if v_conflicts > 0 then
      raise exception 'Домейнът (или негов поддомейн/родителски домейн) се припокрива с домейн на друго училище. Обърнете се към супер администратор.' using errcode = 'CS001';
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
declare v_row public.school_email_domains; v_conflicts bigint; v_new_active boolean; v_new_sub boolean;
begin
  select * into v_row from public.school_email_domains where id = p_id;
  if not found then raise exception 'Домейнът не е намерен.' using errcode = 'CS001'; end if;
  perform public._target_school(v_row.school_id);
  v_new_active := coalesce(p_active, v_row.active);
  v_new_sub := coalesce(p_allow_subdomains, v_row.allow_subdomains);
  select x.n into v_conflicts from public._domain_overlaps(v_row.domain, v_new_sub, v_row.school_id, p_id) x;
  -- админ на училище не може да активира/разширява домейн така, че да се припокрие с друго училище
  if not public.is_super_admin() and v_new_active and v_conflicts > 0
     and (not v_row.active or (v_new_sub and not v_row.allow_subdomains)) then
    raise exception 'Домейнът (или негов поддомейн/родителски домейн) се припокрива с домейн на друго училище. Обърнете се към супер администратор.' using errcode = 'CS001';
  end if;
  update public.school_email_domains set active = v_new_active, allow_subdomains = v_new_sub where id = p_id;
  return jsonb_build_object('id', p_id, 'conflict_count', v_conflicts);
end;
$$;
revoke all on function public.admin_update_domain(bigint, boolean, boolean) from public, anon;
grant execute on function public.admin_update_domain(bigint, boolean, boolean) to authenticated;

-- ---------- 5. Покана: не „краде“ домейн на друго училище ---------------------------
create or replace function public.admin_invite_teacher(p_email text, p_school uuid default null)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._target_school(p_school);
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_domain text;
  v_id bigint; v_foreign int; v_own int;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(v_email) > 254 then
    raise exception 'Невалиден имейл адрес.' using errcode = 'CS001';
  end if;
  v_domain := split_part(v_email, '@', 2);
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception 'Този имейл вече е регистриран.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.school_invites i
              where i.email = v_email and i.status = 'pending' and i.expires_at > now() and i.school_id <> v_school) then
    raise exception 'За този имейл има покана от друго училище.' using errcode = 'CS001';
  end if;
  if not public.is_super_admin() then
    select count(*) filter (where e.school_id <> v_school), count(*) filter (where e.school_id = v_school)
      into v_foreign, v_own
      from public.school_email_domains e join public.schools s on s.id = e.school_id
     where e.active and s.status = 'active'
       and (e.domain = v_domain
            or (e.allow_subdomains and right(v_domain, char_length(e.domain) + 1) = '.' || e.domain));
    if v_foreign > 0 and v_own = 0 then
      raise exception 'Домейнът на този имейл е разрешен за друго училище – покана не може да бъде изпратена.' using errcode = 'CS001';
    end if;
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

commit;
