-- =====================================================================
-- v3.0 / МНОГОУЧИЛИЩНА СИСТЕМА – ЧАСТ 3 от 3: конфигурируем график по училище
-- Файл: 20261014000000_school_schedule_config.sql
-- Предполага 20261012 и 20261013.
--
-- Режими:
--   two_shifts (по подразбиране = днешното поведение): смяна 1 и 2, по 7 позиции;
--       интервалите се пазят ПО СМЯНА НА КОНСУЛТАЦИЯТА (shift = стойността в consultations.shift),
--       затова днешното правило „избрана I смяна -> часове 12:35–18:30, избрана II -> 07:30–13:15“
--       е просто съдържание на данните: (shift 1, 1..7) = 12:35..18:30; (shift 2, 1..7) = 07:30..13:15.
--   one_shift: една обща смяна (shift = 1), позиции 1..N (N до 14), всяка със собствен начало/край.
-- Ключът за конфликти остава (ден, смяна, час); consultations.shift НЕ се преобразува масово.
-- Консултации никога не се изтриват и не се пренаписват автоматично:
--   * позиция, която се използва, не може да се изтрие/преномерира (RPC + външен ключ в базата);
--   * смяна на режим, която би осиротила консултации, се отказва;
--   * промяна на час на използвана позиция изисква изрично потвърждение.
-- Идемпотентна.
-- =====================================================================

begin;

create table if not exists public.school_schedule_settings (
  school_id  uuid primary key references public.schools (id) on delete cascade,
  mode       text not null default 'two_shifts',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null,
  constraint school_schedule_mode check (mode in ('one_shift', 'two_shifts'))
);

create table if not exists public.school_intervals (
  id         bigint generated always as identity primary key,
  school_id  uuid not null references public.schools (id) on delete cascade,
  shift      int  not null,
  position   int  not null,
  start_time time not null,
  end_time   time not null,
  constraint school_intervals_shift check (shift in (1, 2)),
  constraint school_intervals_position check (position between 1 and 14),
  constraint school_intervals_order check (start_time < end_time),
  constraint school_intervals_minutes check (extract(second from start_time) = 0 and extract(second from end_time) = 0),
  constraint school_intervals_uq unique (school_id, shift, position)
);

alter table public.school_schedule_settings enable row level security;
alter table public.school_intervals         enable row level security;
revoke all on public.school_schedule_settings, public.school_intervals from public, anon, authenticated;
grant select on public.school_schedule_settings, public.school_intervals to authenticated;

do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
            where schemaname = 'public' and tablename in ('school_schedule_settings', 'school_intervals')
  loop execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename); end loop;
end $$;
create policy school_schedule_settings_select on public.school_schedule_settings
  for select to authenticated using (school_id = public.current_school_id());
create policy school_intervals_select on public.school_intervals
  for select to authenticated using (school_id = public.current_school_id());

-- ---------- Подразбиращи се интервали (13 реални слота) -----------------------
create or replace function public._default_interval(p_slot int)
returns table (start_time time, end_time time)
language sql immutable
set search_path = public, pg_temp
as $$
  select (a[p_slot][1])::time, (a[p_slot][2])::time
    from (select array[
      array['07:30','08:10'], array['08:20','09:00'], array['09:10','09:50'], array['10:10','10:50'],
      array['11:00','11:40'], array['11:50','12:30'], array['12:35','13:15'], array['13:30','14:10'],
      array['14:20','15:00'], array['15:10','15:50'], array['16:10','16:50'], array['17:00','17:40'],
      array['17:50','18:30']] as a) x
   where p_slot between 1 and 13
$$;
revoke all on function public._default_interval(int) from public, anon, authenticated;

-- две смени: смяна 1 -> слотове 7..13 (12:35–18:30); смяна 2 -> слотове 1..7 (07:30–13:15)
create or replace function public._seed_two_shift_intervals(p_school uuid, p_shift int)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  insert into public.school_intervals (school_id, shift, position, start_time, end_time)
  select p_school, p_shift, p, d.start_time, d.end_time
    from generate_series(1, 7) p,
         lateral public._default_interval(case when p_shift = 1 then p + 6 else p end) d
  on conflict (school_id, shift, position) do nothing
$$;
revoke all on function public._seed_two_shift_intervals(uuid, int) from public, anon, authenticated;

create or replace function public._seed_default_schedule(p_school uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.school_schedule_settings (school_id, mode) values (p_school, 'two_shifts')
  on conflict (school_id) do nothing;
  perform public._seed_two_shift_intervals(p_school, 1);
  perform public._seed_two_shift_intervals(p_school, 2);
end;
$$;
revoke all on function public._seed_default_schedule(uuid) from public, anon, authenticated;

create or replace function public._schools_seed_schedule()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public._seed_default_schedule(new.id);
  return new;
end;
$$;
revoke all on function public._schools_seed_schedule() from public, anon, authenticated;
drop trigger if exists schools_seed_schedule on public.schools;
create trigger schools_seed_schedule after insert on public.schools
  for each row execute function public._schools_seed_schedule();

-- съществуващите училища (първоначалното) получават днешния график
do $$
declare r record;
begin
  for r in select s.id from public.schools s
            where not exists (select 1 from public.school_schedule_settings x where x.school_id = s.id)
  loop perform public._seed_default_schedule(r.id); end loop;
end $$;

-- DB-ниво: консултация може да сочи само съществуваща позиция на СВОЕТО училище.
-- NOT VALID: старите редове (напр. от v1.7 с час 8) не се проверяват/пренаписват; новите – да.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'consultations_interval_fk') then
    alter table public.consultations add constraint consultations_interval_fk
      foreign key (school_id, shift, hour) references public.school_intervals (school_id, shift, position)
      on update restrict on delete restrict not valid;
  end if;
end $$;

-- ---------- _slot_valid: по интервалите на училището -------------------------
create or replace function public._slot_valid(p_school uuid, p_shift int, p_hour int)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.school_intervals i
                  where i.school_id = p_school and i.shift = p_shift and i.position = p_hour)
$$;
revoke all on function public._slot_valid(uuid, int, int) from public, anon, authenticated;

-- ---------- Четене --------------------------------------------------------------
-- Режим + интервали на ТЕКУЩОТО училище (за всички членове). С p_with_usage (само админ): брой консултации по позиция.
create or replace function public.get_school_schedule(p_with_usage boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_school uuid := public.current_school_id(); v_mode text;
begin
  if auth.uid() is null or v_school is null then
    raise exception 'Нямате достъп до активно училище.' using errcode = 'CS001';
  end if;
  select s.mode into v_mode from public.school_schedule_settings s where s.school_id = v_school;
  return jsonb_build_object(
    'mode', coalesce(v_mode, 'two_shifts'),
    'intervals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'shift', i.shift, 'position', i.position,
               'start', to_char(i.start_time, 'HH24:MI'), 'end', to_char(i.end_time, 'HH24:MI'),
               'used', case when p_with_usage and public.is_admin() then
                  (select count(*) from public.consultations c
                    where c.school_id = v_school and c.shift = i.shift and c.hour = i.position)
                 else null end)
             order by i.shift, i.position)
        from public.school_intervals i where i.school_id = v_school), '[]'::jsonb));
end;
$$;
revoke all on function public.get_school_schedule(boolean) from public, anon;
grant execute on function public.get_school_schedule(boolean) to authenticated;

-- ---------- Проверка на подредбата ----------------------------------------------
-- В рамките на една смяна позициите са във възходящ ред и не се припокриват.
-- Между смените припокриване е позволено (напр. общото 12:35–13:15).
create or replace function public._validate_shift_intervals(p_school uuid, p_shift int)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r record; v_prev_end time; v_prev_pos int := 0;
begin
  for r in select i.position, i.start_time, i.end_time from public.school_intervals i
            where i.school_id = p_school and i.shift = p_shift order by i.position
  loop
    if r.position <> v_prev_pos + 1 then
      raise exception 'Позициите трябва да са последователни (без пропуски).' using errcode = 'CS001';
    end if;
    if v_prev_end is not null and r.start_time < v_prev_end then
      raise exception 'Интервал % се припокрива или е преди предишния.', r.position using errcode = 'CS001';
    end if;
    v_prev_end := r.end_time; v_prev_pos := r.position;
  end loop;
end;
$$;
revoke all on function public._validate_shift_intervals(uuid, int) from public, anon, authenticated;

-- ---------- Предварителен преглед на промяна на режим -----------------------------
create or replace function public.admin_schedule_change_impact(p_mode text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_cur text; v_total bigint; v_s1 bigint; v_s2 bigint; v_over bigint;
begin
  if p_mode not in ('one_shift', 'two_shifts') then
    raise exception 'Невалиден режим.' using errcode = 'CS001';
  end if;
  select mode into v_cur from public.school_schedule_settings where school_id = v_school;
  select count(*), count(*) filter (where shift = 1), count(*) filter (where shift = 2),
         count(*) filter (where shift = 1 and hour > 7)
    into v_total, v_s1, v_s2, v_over from public.consultations where school_id = v_school;
  return jsonb_build_object(
    'current_mode', v_cur, 'target_mode', p_mode,
    'consultations_total', v_total, 'in_shift_1', v_s1, 'in_shift_2', v_s2,
    'blocked', (p_mode = 'one_shift' and v_s2 > 0) or (p_mode = 'two_shifts' and v_over > 0),
    'reason', case when p_mode = 'one_shift' and v_s2 > 0
                     then format('В смяна II има %s консултации. Изтрийте ги или ги преместете в I смяна, преди да преминете към една смяна.', v_s2)
                   when p_mode = 'two_shifts' and v_over > 0
                     then format('В позиции над 7 има %s консултации – при две смени позициите са 7.', v_over)
                   else null end);
end;
$$;
revoke all on function public.admin_schedule_change_impact(text) from public, anon;
grant execute on function public.admin_schedule_change_impact(text) to authenticated;

-- ---------- Смяна на режим ----------------------------------------------------------
create or replace function public.admin_set_schedule_mode(p_mode text, p_confirm boolean default false)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_cur text; v_impact jsonb; v_total bigint; p int; v_d record;
begin
  perform pg_advisory_xact_lock(hashtext('schedule:' || v_school::text));
  v_impact := public.admin_schedule_change_impact(p_mode);
  v_cur := v_impact ->> 'current_mode';
  if v_cur = p_mode then return; end if;
  if (v_impact ->> 'blocked')::boolean then
    raise exception '%', v_impact ->> 'reason' using errcode = 'CS001';
  end if;
  v_total := (v_impact ->> 'consultations_total')::bigint;
  if v_total > 0 and not coalesce(p_confirm, false) then
    raise exception 'Училището има % консултации. Смяната на режима променя показваните часове – потвърдете.', v_total
      using errcode = 'CS001';
  end if;

  if p_mode = 'one_shift' then
    delete from public.school_intervals where school_id = v_school and shift = 2;   -- смяна 2 е без консултации
    if v_total = 0 then
      delete from public.school_intervals where school_id = v_school and shift = 1;
      for p in 1..7 loop
        select * into v_d from public._default_interval(p);
        insert into public.school_intervals (school_id, shift, position, start_time, end_time)
        values (v_school, 1, p, v_d.start_time, v_d.end_time);
      end loop;
    end if;
  else
    -- обратно към две смени: точно 7 позиции в смяна 1 (допълват се от подразбиращите се), смяна 2 – по подразбиране
    delete from public.school_intervals where school_id = v_school and shift = 1 and position > 7;
    if v_total = 0 then
      delete from public.school_intervals where school_id = v_school;
      perform public._seed_two_shift_intervals(v_school, 1);
    else
      insert into public.school_intervals (school_id, shift, position, start_time, end_time)
      select v_school, 1, g.p, d.start_time, d.end_time
        from generate_series(1, 7) g(p), lateral public._default_interval(g.p + 6) d
       where not exists (select 1 from public.school_intervals i
                          where i.school_id = v_school and i.shift = 1 and i.position = g.p);
    end if;
    perform public._seed_two_shift_intervals(v_school, 2);
    perform public._validate_shift_intervals(v_school, 1);
  end if;

  update public.school_schedule_settings
     set mode = p_mode, updated_at = now(), updated_by = auth.uid()
   where school_id = v_school;
end;
$$;
revoke all on function public.admin_set_schedule_mode(text, boolean) from public, anon;
grant execute on function public.admin_set_schedule_mode(text, boolean) to authenticated;

-- ---------- Добавяне/редакция на интервал -----------------------------------------------
create or replace function public.admin_save_interval(p_shift int, p_position int, p_start time, p_end time,
                                                      p_confirm boolean default false)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_mode text; v_max int; v_used bigint; v_exists boolean;
begin
  perform pg_advisory_xact_lock(hashtext('schedule:' || v_school::text));
  select mode into v_mode from public.school_schedule_settings where school_id = v_school;
  v_mode := coalesce(v_mode, 'two_shifts');
  if p_shift is null or p_position is null or p_start is null or p_end is null then
    raise exception 'Попълнете смяна, позиция, начало и край.' using errcode = 'CS001';
  end if;
  if v_mode = 'one_shift' and p_shift <> 1 then
    raise exception 'При режим „една смяна“ има само една смяна.' using errcode = 'CS001';
  end if;
  if p_shift not in (1, 2) then
    raise exception 'Невалидна смяна.' using errcode = 'CS001';
  end if;
  if p_start >= p_end then
    raise exception 'Началото трябва да е преди края.' using errcode = 'CS001';
  end if;
  if extract(second from p_start) <> 0 or extract(second from p_end) <> 0 then
    raise exception 'Часовете се задават с точност до минута.' using errcode = 'CS001';
  end if;

  select coalesce(max(position), 0) into v_max from public.school_intervals
   where school_id = v_school and shift = p_shift;
  v_exists := exists (select 1 from public.school_intervals
                       where school_id = v_school and shift = p_shift and position = p_position);

  if not v_exists then
    if v_mode = 'two_shifts' then
      raise exception 'При две смени позициите са фиксирани на 7 – редактирайте часовете на съществуващите.' using errcode = 'CS001';
    end if;
    if p_position <> v_max + 1 then
      raise exception 'Нов интервал се добавя в края (позиция %).', v_max + 1 using errcode = 'CS001';
    end if;
    if p_position > 14 then
      raise exception 'Най-много 14 позиции.' using errcode = 'CS001';
    end if;
    insert into public.school_intervals (school_id, shift, position, start_time, end_time)
    values (v_school, p_shift, p_position, p_start, p_end);
  else
    select count(*) into v_used from public.consultations
     where school_id = v_school and shift = p_shift and hour = p_position;
    if v_used > 0 and not coalesce(p_confirm, false)
       and exists (select 1 from public.school_intervals i where i.school_id = v_school and i.shift = p_shift
                    and i.position = p_position and (i.start_time <> p_start or i.end_time <> p_end)) then
      raise exception 'Интервалът се използва от % консултации. Промяната на часа ще се отрази на всички – потвърдете.', v_used
        using errcode = 'CS001';
    end if;
    update public.school_intervals set start_time = p_start, end_time = p_end
     where school_id = v_school and shift = p_shift and position = p_position;
  end if;

  perform public._validate_shift_intervals(v_school, p_shift);
end;
$$;
revoke all on function public.admin_save_interval(int, int, time, time, boolean) from public, anon;
grant execute on function public.admin_save_interval(int, int, time, time, boolean) to authenticated;

-- ---------- Изтриване на интервал (само последният, неизползван; без преномериране) ----------
create or replace function public.admin_delete_interval(p_shift int, p_position int)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_school uuid := public._admin_school();
  v_mode text; v_max int; v_used bigint;
begin
  perform pg_advisory_xact_lock(hashtext('schedule:' || v_school::text));
  select mode into v_mode from public.school_schedule_settings where school_id = v_school;
  if coalesce(v_mode, 'two_shifts') <> 'one_shift' then
    raise exception 'Интервали се премахват само при режим „една смяна“.' using errcode = 'CS001';
  end if;
  select max(position) into v_max from public.school_intervals where school_id = v_school and shift = p_shift;
  if v_max is null or p_position is distinct from v_max then
    raise exception 'Може да се премахне само последният интервал (без преномериране).' using errcode = 'CS001';
  end if;
  if v_max <= 1 then
    raise exception 'Трябва да остане поне един интервал.' using errcode = 'CS001';
  end if;
  select count(*) into v_used from public.consultations
   where school_id = v_school and shift = p_shift and hour = p_position;
  if v_used > 0 then
    raise exception 'Интервалът се използва от % консултации и не може да бъде премахнат.', v_used using errcode = 'CS001';
  end if;
  delete from public.school_intervals where school_id = v_school and shift = p_shift and position = p_position;
end;
$$;
revoke all on function public.admin_delete_interval(int, int) from public, anon;
grant execute on function public.admin_delete_interval(int, int) to authenticated;

-- ---------- Диагностика на стари редове (само NOTICE) -------------------------------------
do $$
declare v_bad bigint;
begin
  select count(*) into v_bad from public.consultations c
   where not exists (select 1 from public.school_intervals i
                      where i.school_id = c.school_id and i.shift = c.shift and i.position = c.hour);
  raise notice 'Консултации без съответна позиция в графика на училището (не се променят): %', v_bad;
end $$;

commit;
