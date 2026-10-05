-- =====================================================================
-- График за консултации: hardening + сървърна проверка за конфликти
-- Идемпотентна миграция (може да се пусне повторно).
-- Предполага вече създадените таблици: teachers, classes, consultations,
-- consultation_classes, group_subjects.
-- Бизнес грешки се връщат с SQLSTATE 'CS001' и български текст.
-- =====================================================================

-- ---------- 1. Помощни функции ----------------------------------------

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.teachers t
    where t.id = auth.uid() and t.role = 'admin'
  );
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Автоматичен профил при нов auth user. Ролята НИКОГА не се взима от
-- user metadata (то е контролирано от потребителя) - винаги 'teacher'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_name text;
begin
  v_name := nullif(btrim(coalesce(new.raw_user_meta_data->>'name', '')), '');
  v_name := coalesce(v_name, nullif(btrim(coalesce(new.email, '')), ''), 'Потребител');
  insert into public.teachers (id, name, role)
  values (new.id, left(v_name, 100), 'teacher')
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke all on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;

drop trigger if exists consultations_set_updated_at on public.consultations;
create trigger consultations_set_updated_at
  before update on public.consultations
  for each row execute function public.set_updated_at();

-- Учител не може да си смени ролята; не може да се премахне последният админ.
create or replace function public.teachers_protect_role()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'Идентификаторът не може да се променя.' using errcode = 'CS001';
  end if;
  if new.role is distinct from old.role then
    if not public.is_admin() then
      raise exception 'Нямате право да променяте роли.' using errcode = 'CS001';
    end if;
    if old.role = 'admin' and not exists (
         select 1 from public.teachers where role = 'admin' and id <> old.id) then
      raise exception 'Не може да бъде премахнат последният администратор.' using errcode = 'CS001';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists teachers_protect_role on public.teachers;
create trigger teachers_protect_role
  before update on public.teachers
  for each row execute function public.teachers_protect_role();

-- ---------- 2. Ограничения и индекси ----------------------------------

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'teachers_name_len') then
    alter table public.teachers add constraint teachers_name_len
      check (char_length(btrim(name)) between 1 and 100);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'consultations_subject_len') then
    alter table public.consultations add constraint consultations_subject_len
      check (char_length(btrim(subject)) between 1 and 100);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'consultations_location_len') then
    alter table public.consultations add constraint consultations_location_len
      check (location is null or char_length(location) <= 100);
  end if;
end $$;

-- Един учител не може да има две консултации в един слот (твърда гаранция).
create unique index if not exists consultations_teacher_slot_uq
  on public.consultations (teacher_id, day, shift, hour);
create index if not exists consultations_slot_idx
  on public.consultations (day, shift, hour);
create index if not exists consultation_classes_class_idx
  on public.consultation_classes (class_id);
create unique index if not exists group_subjects_subject_uq
  on public.group_subjects (lower(btrim(subject)));

-- ---------- 3. RLS политики -------------------------------------------

alter table public.teachers              enable row level security;
alter table public.classes               enable row level security;
alter table public.consultations         enable row level security;
alter table public.consultation_classes  enable row level security;
alter table public.group_subjects        enable row level security;

-- Изчистваме всички стари политики (непознати имена) и ги създаваме наново.
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('teachers','classes','consultations','consultation_classes','group_subjects')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- teachers: всички влезли виждат имената; всеки сменя само своя ред
-- (ролята е защитена от trigger); админ управлява всичко.
create policy teachers_select on public.teachers
  for select to authenticated using (true);
create policy teachers_update_own on public.teachers
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy teachers_admin_all on public.teachers
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy classes_select on public.classes
  for select to authenticated using (true);
create policy classes_admin_all on public.classes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy group_subjects_select on public.group_subjects
  for select to authenticated using (true);
create policy group_subjects_admin_all on public.group_subjects
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- consultations / consultation_classes: четене за всички влезли;
-- ЗАПИС само през RPC (security definer) -> няма INSERT/UPDATE политики,
-- така че проверката за конфликти не може да бъде заобиколена.
create policy consultations_select on public.consultations
  for select to authenticated using (true);
create policy consultations_delete on public.consultations
  for delete to authenticated using (teacher_id = auth.uid() or public.is_admin());

create policy consultation_classes_select on public.consultation_classes
  for select to authenticated using (true);

-- Defense in depth: права на ниво GRANT (TRUNCATE не се филтрира от RLS).
revoke all on public.teachers, public.classes, public.consultations,
              public.consultation_classes, public.group_subjects from anon;
revoke truncate, trigger, references on public.teachers, public.classes,
              public.consultations, public.consultation_classes,
              public.group_subjects from authenticated;
revoke insert, update on public.consultations, public.consultation_classes from authenticated;
revoke delete on public.consultation_classes from authenticated;

-- ---------- 4. Основна логика със заключване и проверка ---------------

create or replace function public._save_consultation(
  p_id bigint, p_teacher uuid, p_day int, p_shift int, p_hour int,
  p_subject text, p_location text, p_classes text[]
) returns bigint
language plpgsql security definer
set search_path = public
as $$
declare
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
  if p_day not between 1 and 5 or p_shift not between 1 and 2 or p_hour not between 1 and 8 then
    raise exception 'Невалиден ден, смяна или час.' using errcode = 'CS001';
  end if;
  if v_subject = '' or char_length(v_subject) > 100 then
    raise exception 'Моля, въведете предмет (до 100 символа).' using errcode = 'CS001';
  end if;
  if v_location is not null and char_length(v_location) > 100 then
    raise exception 'Мястото е твърде дълго (до 100 символа).' using errcode = 'CS001';
  end if;

  select array_agg(c.id) into v_class_ids from public.classes c where c.name = any (p_classes);
  if coalesce(cardinality(v_class_ids), 0) = 0
     or cardinality(v_class_ids) <> (select count(distinct x) from unnest(p_classes) x) then
    raise exception 'Невалиден избор на клас.' using errcode = 'CS001';
  end if;

  -- Сериализира конкурентни записи за един и същ слот (race conditions).
  perform pg_advisory_xact_lock(hashtext('consultation_slot'), p_day * 100 + p_shift * 10 + p_hour);

  if exists (select 1 from public.consultations c
             where c.teacher_id = p_teacher and c.day = p_day and c.shift = p_shift
               and c.hour = p_hour and (p_id is null or c.id <> p_id)) then
    raise exception 'Учителят вече има друга консултация в този час.' using errcode = 'CS001';
  end if;

  v_is_group := exists (select 1 from public.group_subjects g
                        where g.enabled and lower(btrim(g.subject)) = lower(v_subject));
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
    insert into public.consultations (teacher_id, day, shift, hour, subject, location)
    values (p_teacher, p_day, p_shift, p_hour, v_subject, v_location)
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

  insert into public.consultation_classes (consultation_id, class_id)
  select v_id, unnest(v_class_ids)
  on conflict do nothing;

  return v_id;
end;
$$;
revoke all on function public._save_consultation(bigint, uuid, int, int, int, text, text, text[])
  from public, anon, authenticated;

-- Публичен вход: създаване (p_id null) или редакция.
create or replace function public.save_consultation(
  p_id bigint, p_day int, p_shift int, p_hour int,
  p_subject text, p_location text, p_classes text[]
) returns bigint
language plpgsql security definer
set search_path = public
as $$
declare v_teacher uuid;
begin
  if auth.uid() is null or not exists (select 1 from public.teachers where id = auth.uid()) then
    raise exception 'Не сте влезли в системата.' using errcode = 'CS001';
  end if;
  if p_id is null then
    v_teacher := auth.uid();
  else
    select teacher_id into v_teacher from public.consultations where id = p_id for update;
    if not found then
      raise exception 'Записът не е намерен.' using errcode = 'CS001';
    end if;
    if v_teacher <> auth.uid() and not public.is_admin() then
      raise exception 'Нямате право да редактирате този запис.' using errcode = 'CS001';
    end if;
  end if;
  return public._save_consultation(p_id, v_teacher, p_day, p_shift, p_hour,
                                   p_subject, p_location, p_classes);
end;
$$;
revoke all on function public.save_consultation(bigint, int, int, int, text, text, text[]) from public, anon;
grant execute on function public.save_consultation(bigint, int, int, int, text, text, text[]) to authenticated;

-- ---------- 5. Админ операции -----------------------------------------

create or replace function public.admin_clear_consultations()
returns integer
language plpgsql security definer
set search_path = public
as $$
declare v_n integer;
begin
  if not public.is_admin() then
    raise exception 'Само администратор може да изпълни тази операция.' using errcode = 'CS001';
  end if;
  with d as (delete from public.consultations where true returning 1)
  select count(*) into v_n from d;
  return v_n;
end;
$$;
revoke all on function public.admin_clear_consultations() from public, anon;
grant execute on function public.admin_clear_consultations() to authenticated;

-- Импорт (миграция от localStorage / възстановяване от backup).
-- p_items: [{teacherId?, teacherName, day(1-5), shift, hour, subject, location, classes:[..]}]
-- Всеки запис се валидира със същата логика; дубликати се пропускат.
create or replace function public.import_consultations(p_items jsonb, p_replace boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_item jsonb; v_idx int := 0; v_teacher uuid; v_name text;
  v_imported int := 0; v_dups int := 0; v_errors jsonb := '[]'::jsonb;
  v_classes text[]; v_day int; v_shift int; v_hour int; v_subject text;
begin
  if not public.is_admin() then
    raise exception 'Само администратор може да импортира данни.' using errcode = 'CS001';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Невалиден формат на данните.' using errcode = 'CS001';
  end if;
  if p_replace then delete from public.consultations where true; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_idx := v_idx + 1;
    begin
      v_teacher := null;
      if (v_item->>'teacherId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        select id into v_teacher from public.teachers where id = (v_item->>'teacherId')::uuid;
      end if;
      v_name := btrim(coalesce(v_item->>'teacherName', ''));
      if v_teacher is null and v_name <> '' then
        select id into v_teacher from public.teachers
         where lower(btrim(name)) = lower(v_name)
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
                 where c.teacher_id = v_teacher and c.day = v_day and c.shift = v_shift
                   and c.hour = v_hour and lower(btrim(c.subject)) = lower(v_subject)) then
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

-- ---------- 6. Realtime -----------------------------------------------

do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['consultations', 'consultation_classes', 'group_subjects'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
