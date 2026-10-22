-- =====================================================================
-- ВЪЗСТАНОВЯВАНЕ на функциите/политиките/тригерите на v2.9 СЛЕД manual/rollback_multi_school.sql.
-- Генерирано от старите миграции (без стъпката за „физически слот“ на 20261006, която би
-- създала уникален индекс, несъвместим с вече записани I/7 и II/1 клетки).
-- Редът: 20260101 (цялата) -> 20261006 (раздели 4–6: класове, премахване на учител, Realtime) ->
--        20261007 (admin_add_class 5–12) -> 20261008 (цялата) -> 20261010 (цялата) -> 20261011 (цялата).
-- Идемпотентно; не променя данни.
-- =====================================================================
begin;

-- ===== 20260101000000_secure_consultations.sql =====
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


-- ===== 20261006000000 (раздели 4-6) =====
-- ---------- 4. Класове ------------------------------------------------
-- Добавяне: валидира (1..12 + една буква А-Я), превръща латински двойници в кирилица
-- и отказва и "невидими" дубликати (напр. латинско A срещу кирилско А).
create or replace function public.admin_add_class(p_grade int, p_letter text)
returns bigint
language plpgsql security definer
set search_path = public
as $$
declare
  v_letter text := translate(btrim(coalesce(p_letter, '')), 'ABEKMHOPCTX', 'АВЕКМНОРСТХ');
  v_name   text;
  v_id     bigint;
begin
  if not public.is_admin() then
    raise exception 'Само администратор може да управлява класовете.' using errcode = 'CS001';
  end if;
  if p_grade is null or p_grade not between 1 and 12 then
    raise exception 'Номерът на класа трябва да е от 1 до 12.' using errcode = 'CS001';
  end if;
  if v_letter !~ '^[А-Я]$' then
    raise exception 'Паралелката трябва да е една главна буква (А-Я).' using errcode = 'CS001';
  end if;
  v_name := p_grade::text || v_letter;

  perform pg_advisory_xact_lock(hashtext('classes_admin'));
  if exists (select 1 from public.classes where translate(name, 'ABEKMHOPCTX', 'АВЕКМНОРСТХ') = v_name) then
    raise exception 'Класът % вече съществува.', v_name using errcode = 'CS001';
  end if;

  insert into public.classes (name) values (v_name) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.admin_add_class(int, text) from public, anon;
grant execute on function public.admin_add_class(int, text) to authenticated;

-- Изтриване на клас с консултации се блокира в самата база (важи и за директни API заявки);
-- иначе ON DELETE CASCADE би оставил консултации без клас.
create or replace function public.classes_protect_delete()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_n int;
begin
  select count(*) into v_n from public.consultation_classes where class_id = old.id;
  if v_n > 0 then
    raise exception 'Клас % има % консултации и не може да бъде изтрит.', old.name, v_n using errcode = 'CS001';
  end if;
  return old;
end;
$$;
drop trigger if exists classes_protect_delete on public.classes;
create trigger classes_protect_delete
  before delete on public.classes
  for each row execute function public.classes_protect_delete();

-- ---------- 5. Премахване на учител -----------------------------------
-- Атомарно (една транзакция): консултациите на учителя -> Auth акаунтът -> (каскадно) teachers.
-- Не ползва service_role: функцията е SECURITY DEFINER и е достъпна само за админ.
-- Консултациите се изтриват явно, за да не зависи операцията от ON DELETE на FK-то.
create or replace function public.admin_delete_teacher(p_teacher uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_role text;
  v_n    int;
begin
  if not public.is_admin() then
    raise exception 'Само администратор може да премахва учители.' using errcode = 'CS001';
  end if;
  if p_teacher is null then
    raise exception 'Невалиден потребител.' using errcode = 'CS001';
  end if;
  if p_teacher = auth.uid() then
    raise exception 'Не можете да премахнете собствения си акаунт.' using errcode = 'CS001';
  end if;

  -- заключва реда; едновременна консултация от този учител изчаква (FK проверката)
  select role into v_role from public.teachers where id = p_teacher for update;
  if not found then
    raise exception 'Учителят не е намерен.' using errcode = 'CS001';
  end if;
  if v_role = 'admin' and (select count(*) from public.teachers where role = 'admin') <= 1 then
    raise exception 'Не може да бъде премахнат последният администратор.' using errcode = 'CS001';
  end if;

  delete from public.consultations where teacher_id = p_teacher;
  get diagnostics v_n = row_count;

  -- каскадно изтрива и public.teachers (teachers.id -> auth.users ON DELETE CASCADE)
  delete from auth.users where id = p_teacher;

  if exists (select 1 from public.teachers where id = p_teacher) then
    raise exception 'Неуспешно премахване на акаунта.' using errcode = 'CS001';   -- откат на всичко
  end if;

  return jsonb_build_object('consultations_deleted', v_n);
end;
$$;
revoke all on function public.admin_delete_teacher(uuid) from public, anon;
grant execute on function public.admin_delete_teacher(uuid) to authenticated;

-- ---------- 6. Realtime за класове и учители --------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['classes', 'teachers'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;


-- ===== 20261007000000 (admin_add_class 5-12) =====
create or replace function public.admin_add_class(p_grade int, p_letter text)
returns bigint
language plpgsql security definer
set search_path = public
as $$
declare
  v_letter text := translate(btrim(coalesce(p_letter, '')), 'ABEKMHOPCTX', 'АВЕКМНОРСТХ');
  v_name   text;
  v_id     bigint;
begin
  if not public.is_admin() then
    raise exception 'Само администратор може да управлява класовете.' using errcode = 'CS001';
  end if;
  if p_grade is null or p_grade not between 5 and 12 then
    raise exception 'Номерът на класа трябва да е от 5 до 12.' using errcode = 'CS001';
  end if;
  if v_letter !~ '^[А-Я]$' then
    raise exception 'Паралелката трябва да е една главна буква (А-Я).' using errcode = 'CS001';
  end if;
  v_name := p_grade::text || v_letter;

  perform pg_advisory_xact_lock(hashtext('classes_admin'));
  if exists (select 1 from public.classes where translate(name, 'ABEKMHOPCTX', 'АВЕКМНОРСТХ') = v_name) then
    raise exception 'Класът % вече съществува.', v_name using errcode = 'CS001';
  end if;

  insert into public.classes (name) values (v_name) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.admin_add_class(int, text) from public, anon;
grant execute on function public.admin_add_class(int, text) to authenticated;

-- ===== 20261008000000 =====
-- =====================================================================
-- v2.3: смените са НЕЗАВИСИМИ - слотът е (ден, смяна, час), без "физически слот"
-- Идемпотентна. Не променя таблици, RLS, Realtime.
--
-- ПРИЧИНА: v2.1 въведе slot_of(shift, hour) (I/7 == II/1) и го вгради в:
--   1) уникалния индекс consultations_teacher_slot_uq,
--   2) заключването на слота (pg_advisory_xact_lock),
--   3) проверката за заетост на учител,
--   4) проверката за клас / паралелни групи,
--   5) дубликатите при импорт.
-- Затова една консултация в I смяна/7 (12:35-13:15) блокираше II смяна/1 (12:35-13:15).
-- 12:35-13:15 е само еднакъв етикет; I/7 и II/1 са две различни клетки.
--
-- ВРЪЩА: всички проверки към (ден, смяна, час), както е при една смяна:
--   - един учител не може да има две консултации в една и съща клетка;
--   - клас/паралелни групи се броят само в рамките на същата клетка.
-- РАЗРЕШЕНО (между I/7 и II/1): един и същ учител, предмет, класове и място.
--
-- ОБРАТИМОСТ: за да се върне предишното поведение, пуснете наново
--   20261006000000_hours_classes_teachers.sql и 20261007000000_separate_shift_cells.sql.
--
-- ЗАБЕЛЕЖКА: записи, създадени с v2.1 във II смяна/1-ви час, са били записани като
-- (I смяна, 7) и не могат да бъдат различени (вижте README).
-- =====================================================================

-- ---------- 1. Уникален индекс: учител + ден + смяна + час -------------
drop index if exists public.consultations_teacher_slot_uq;
create unique index consultations_teacher_slot_uq
  on public.consultations (teacher_id, day, shift, hour);

-- ---------- 2. Запис (conflict checks по ден+смяна+час) ----------------
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
  if p_day not between 1 and 5 or p_shift not between 1 and 2 or p_hour not between 1 and 7 then
    raise exception 'Невалиден ден, смяна или час.' using errcode = 'CS001';
  end if;
  -- Слотът е (ден, смяна, час). I смяна/7 и II смяна/1 са независими клетки (12:35 - 13:15 е
  -- само еднакъв етикет) – записват се както са и не си пречат помежду си.

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
             where c.teacher_id = p_teacher and c.day = p_day
               and c.shift = p_shift and c.hour = p_hour
               and (p_id is null or c.id <> p_id)) then
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

-- ---------- 3. Импорт (дубликатите - по ден+смяна+час) -----------------
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

-- ---------- 4. Премахване на концепцията "физически слот" --------------
-- Индексът и функциите по-горе вече не я ползват.
drop function if exists public.slot_of(int, int);

-- Диагностика (само NOTICE)
do $$
declare v_s1 int; v_s2 int;
begin
  select count(*) filter (where shift = 1 and hour = 7), count(*) filter (where shift = 2 and hour = 1)
    into v_s1, v_s2 from public.consultations;
  raise notice 'Записи в 12:35-13:15: I смяна/7 = %, II смяна/1 = %', v_s1, v_s2;
end $$;


-- ===== 20261010000000 =====
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


-- ===== 20261011000000 =====
-- =====================================================================
-- v2.9: свободен избор на смяна – премахва ограниченията от 20261009000000.
-- 20261009 принуждаваше етап -> смяна (гимназия само II, прогимназия само I) и забраняваше
-- консултации със смесени етапи. Това противоречи на умисленото поведение (свободен избор на
-- I/II смяна; автоматичното обръщане при смяна на етап е само UX във frontend-а).
--
-- Тази миграция само пренаписва _save_consultation със същата логика като 20261008000000:
--   слотът е (ден, смяна, час); I/7 и II/1 са независими; учител/клас/паралелни групи в рамките
--   на една и съща клетка; без проверка на етапа спрямо смяната.
-- Идемпотентна. Не пипа старите миграции, таблици, индекси, RLS и публичния save_consultation.
-- Помощните обекти от 20261009 (consultation_stage_shifts, get_consultation_stage_shifts,
-- consultation_stage_of_class) остават неизползвани и безвредни.
-- =====================================================================

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
  if p_day not between 1 and 5 or p_shift not between 1 and 2 or p_hour not between 1 and 7 then
    raise exception 'Невалиден ден, смяна или час.' using errcode = 'CS001';
  end if;
  -- Слотът е (ден, смяна, час). I смяна/7 и II смяна/1 са независими клетки (12:35 - 13:15 е
  -- само еднакъв етикет) – записват се както са и не си пречат помежду си.

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
             where c.teacher_id = p_teacher and c.day = p_day
               and c.shift = p_shift and c.hour = p_hour
               and (p_id is null or c.id <> p_id)) then
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


commit;
