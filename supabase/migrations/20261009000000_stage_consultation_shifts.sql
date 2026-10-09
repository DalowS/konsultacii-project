-- v2.6: една училищна настройка задава редовните смени; консултациите са в обратната смяна.
-- Текуща настройка: гимназия I, прогимназия II. Смесен запис няма една допустима смяна.

create table if not exists public.consultation_stage_shifts (
  stage text primary key check (stage in ('gymnasium', 'progymnasium')),
  regular_shift int not null check (regular_shift in (1, 2))
);

insert into public.consultation_stage_shifts (stage, regular_shift)
values ('gymnasium', 1), ('progymnasium', 2)
on conflict (stage) do nothing;

-- Настройката е достъпна само през SECURITY DEFINER функциите по-долу.
alter table public.consultation_stage_shifts enable row level security;
revoke all on public.consultation_stage_shifts from public, anon, authenticated;

create or replace function public._get_consultation_stage_shifts()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_gym int;
  v_prog int;
begin
  select max(regular_shift) filter (where stage = 'gymnasium'),
         max(regular_shift) filter (where stage = 'progymnasium')
    into v_gym, v_prog
    from public.consultation_stage_shifts;

  if v_gym is null or v_prog is null or v_gym not in (1, 2) or v_prog not in (1, 2) or v_gym = v_prog then
    raise exception 'Настройката за редовните смени на етапите е невалидна.' using errcode = 'CS001';
  end if;

  return jsonb_build_object('gymnasium', v_gym, 'progymnasium', v_prog);
end;
$$;
revoke all on function public._get_consultation_stage_shifts() from public, anon, authenticated;

-- Frontend-ът получава същата настройка, която използва RPC при запис.
create or replace function public.get_consultation_stage_shifts()
returns jsonb
language sql stable security definer
set search_path = public
as $$ select public._get_consultation_stage_shifts() $$;
revoke all on function public.get_consultation_stage_shifts() from public, anon;
grant execute on function public.get_consultation_stage_shifts() to authenticated;

create or replace function public.consultation_stage_of_class(p_name text)
returns text
language plpgsql immutable
set search_path = public
as $$
declare v_grade int;
begin
  v_grade := nullif(substring(btrim(coalesce(p_name, '')) from '^[0-9]{1,2}'), '')::int;
  if v_grade between 5 and 7 then return 'progymnasium'; end if;
  if v_grade between 8 and 12 then return 'gymnasium'; end if;
  return null;
end;
$$;
revoke all on function public.consultation_stage_of_class(text) from public, anon, authenticated;

-- Server-side authoritative save: stage is inferred from the selected class names.
-- The logical slot remains (day, shift, hour); no physical-time comparison is added.
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
  v_stage_count bigint;
  v_stage text;
  v_unclassified boolean;
  v_stage_shifts jsonb;
  v_regular_shift int;
  v_expected_shift int;
  v_shift_name text;
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

  select count(distinct stage), min(stage), bool_or(stage is null)
    into v_stage_count, v_stage, v_unclassified
    from (
      select public.consultation_stage_of_class(c.name) as stage
        from public.classes c where c.id = any (v_class_ids)
    ) selected_classes;

  if coalesce(v_unclassified, false) or v_stage_count = 0 then
    raise exception 'Изберете класове от Гимназиален или Прогимназиален етап.' using errcode = 'CS001';
  end if;
  if v_stage_count > 1 then
    raise exception 'Една консултация може да включва класове само от един етап, защото етапите са в различни консултационни смени.' using errcode = 'CS001';
  end if;

  v_stage_shifts := public._get_consultation_stage_shifts();
  v_regular_shift := (v_stage_shifts ->> v_stage)::int;
  v_expected_shift := 3 - v_regular_shift;
  if p_shift <> v_expected_shift then
    v_shift_name := case when v_expected_shift = 1 then 'I' else 'II' end;
    raise exception 'Консултациите за този етап се провеждат само в % смяна.', v_shift_name using errcode = 'CS001';
  end if;

  -- Слотът е (ден, смяна, час); I/7 и II/1 са отделни логически клетки.
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
