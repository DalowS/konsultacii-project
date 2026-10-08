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
