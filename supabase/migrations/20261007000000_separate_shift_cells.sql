-- =====================================================================
-- v2.2: отделни клетки за 12:35-13:15 + класове само 5-12
-- Идемпотентна. Не променя таблици, RLS, Realtime и индекси.
--
-- 1) _save_consultation: премахнато е канонизирането (II смяна/1 -> I смяна/7).
--    I смяна/7-ми час и II смяна/1-ви час вече са две отделни клетки в базата.
--    slot_of() остава САМО за проверка на реален времеви конфликт (учител, клас,
--    заключване на слота, уникалния индекс по учител+ден+слот).
--    Съобщенията за конфликт в слот 7 споменават, че интервалът е общ за двете смени.
-- 2) admin_add_class: 5..12 (етапите са гимназиален 8-12 и прогимназиален 5-7).
--
-- ВНИМАНИЕ: записи, създадени с v2.1 във II смяна/1-ви час, са били записани като
-- (I смяна, 7) и не могат да бъдат различени. Вижте README (раздел "Общ час").
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
  v_slot      int;
  v_hint      text;
begin
  if p_day not between 1 and 5 or p_shift not between 1 and 2 or p_hour not between 1 and 7 then
    raise exception 'Невалиден ден, смяна или час.' using errcode = 'CS001';
  end if;
  -- Клетките са ОТДЕЛНИ: (I смяна, 7) и (II смяна, 1) се записват такива, каквито са.
  -- Физическият слот (12:35-13:15 е общ интервал) се ползва САМО за проверка на реален
  -- времеви конфликт: един учител/клас не може да е на две места в един и същ интервал.
  v_slot := public.slot_of(p_shift, p_hour);
  v_hint := case when v_slot = 7 then ' 12:35 - 13:15 е общ интервал за двете смени.' else '' end;

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
    raise exception 'Учителят вече има друга консултация в този час.%', v_hint using errcode = 'CS001';
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
        raise exception 'Клас % вече има консултация в този час.%', v_cname, v_hint using errcode = 'CS001';
      elsif v_n >= 2 then
        raise exception 'Клас %: вече има две групи в този час.%', v_cname, v_hint using errcode = 'CS001';
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

-- Диагностика (само NOTICE): записи в общия интервал по смени
do $$
declare v_s1 int; v_s2 int;
begin
  select count(*) filter (where shift = 1 and hour = 7), count(*) filter (where shift = 2 and hour = 1)
    into v_s1, v_s2 from public.consultations;
  raise notice 'Записи в 12:35-13:15: I смяна/7 = %, II смяна/1 = %', v_s1, v_s2;
end $$;
