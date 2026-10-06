-- =====================================================================
-- v2.1: часове (общ слот 12:35-13:15), класове, премахване на учители
-- Идемпотентна. Не променя схемата на таблиците.
--
-- МОДЕЛ НА ЧАСОВЕТЕ (без промяна на колоните):
--   shift 1..2, hour 1..7 (позиция в смяната)
--   slot = shift 1 ? hour : hour + 6      -> 13 физически слота
--   I смяна = слотове 1..7, II смяна = слотове 7..13
--   слот 7 (12:35-13:15) е общ: (1,7) и (2,1) са едно и също време.
--
-- ВНИМАНИЕ ЗА СТАРИ ДАННИ: в v1.7 "I смяна" беше следобедната (12:35-18:30),
-- "II смяна" - сутрешната, и имаше 8 часа. Съществуващите записи НЕ се променят
-- автоматично. Вижте NOTICE-а най-долу и README (раздел "Стари записи").
-- =====================================================================

-- ---------- 1. Физически слот ----------------------------------------
create or replace function public.slot_of(p_shift int, p_hour int)
returns int
language sql immutable parallel safe
as $$ select case when p_shift = 1 then p_hour else p_hour + 6 end $$;

-- Един учител - една консултация на физически слот (покрива общия час между смените).
drop index if exists public.consultations_teacher_slot_uq;
create unique index consultations_teacher_slot_uq
  on public.consultations (teacher_id, day, (public.slot_of(shift, hour)));

-- ---------- 2. Запис с проверка по физически слот ---------------------
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
  v_slot      int;
begin
  if p_day not between 1 and 5 or p_shift not between 1 and 2 or p_hour not between 1 and 7 then
    raise exception 'Невалиден ден, смяна или час.' using errcode = 'CS001';
  end if;
  -- Общият час 12:35-13:15 е ЕДИН физически слот: II смяна/1-ви час == I смяна/7-ми час.
  -- Записваме го винаги като (1, 7); проверките по-долу ползват slot_of() и за стари редове.
  if p_shift = 2 and p_hour = 1 then p_shift := 1; p_hour := 7; end if;
  v_slot := public.slot_of(p_shift, p_hour);

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
  perform pg_advisory_xact_lock(hashtext('consultation_slot'), p_day * 100 + v_slot);

  if exists (select 1 from public.consultations c
             where c.teacher_id = p_teacher and c.day = p_day
               and public.slot_of(c.shift, c.hour) = v_slot
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
     where oc.class_id = v_cid and o.day = p_day and public.slot_of(o.shift, o.hour) = v_slot
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

-- ---------- 3. Импорт (дубликатите се търсят по физически слот) -------
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
                   and public.slot_of(c.shift, c.hour) = public.slot_of(v_shift, v_hour)
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

-- ---------- 7. Диагностика на стари данни (само NOTICE, нищо не се променя) ----
do $$
declare v_total int; v_bad int; v_s1 int; v_s2 int;
begin
  select count(*), count(*) filter (where hour > 7),
         count(*) filter (where shift = 1), count(*) filter (where shift = 2)
    into v_total, v_bad, v_s1, v_s2 from public.consultations;
  raise notice 'Консултации: % (смяна 1: %, смяна 2: %). С невалиден час (>7, трябва да се прегледат): %',
    v_total, v_s1, v_s2, v_bad;
end $$;
