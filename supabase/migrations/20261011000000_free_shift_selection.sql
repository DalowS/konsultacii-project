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
