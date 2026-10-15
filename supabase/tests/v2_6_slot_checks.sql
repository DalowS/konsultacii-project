-- =====================================================================
-- v2.6: слотът е (ден, смяна, час). Сценарии 1-6 от задачата, през реалния RPC save_consultation.
-- Работи в транзакция и завършва с ROLLBACK. Резултат: таблица (test, ok, detail).
-- Пускане: Supabase SQL Editor (или psql) СЛЕД миграциите, включително 20261008000000.
-- =====================================================================
begin;
create temp table res(test text, ok boolean, detail text) on commit drop;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;

create or replace function pg_temp.try_save(p_name text, p_expect_ok boolean, p_user uuid, p_day int, p_shift int, p_hour int,
                                            p_subject text, p_location text, p_classes text[]) returns void language plpgsql as $$
begin
  perform pg_temp.as_user(p_user);
  begin
    perform public.save_consultation(null::bigint, p_day, p_shift, p_hour, p_subject, p_location, p_classes);
    insert into res values (p_name, p_expect_ok, case when p_expect_ok then '' else 'очаквана грешка, но записът мина' end);
  exception when others then
    insert into res values (p_name, not p_expect_ok, case when p_expect_ok then sqlerrm else '' end);
  end;
end $$;

do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
begin
  insert into auth.users(id, email) values (a, 'a@paisii.info'), (b, 'b@paisii.info'), (c, 'c@paisii.info');
  insert into public.group_subjects(subject, enabled) values ('ТЕСТГРУПА', true) on conflict (subject) do update set enabled = true;

  -- 1/2: същ учител, същ предмет, различни класове, I/7 и II/1
  perform pg_temp.try_save('1+2 учител+предмет: Пон I/7 Математика 8А', true,  a, 1, 1, 7, 'Математика', '12', array['8А']);
  perform pg_temp.try_save('1+2 учител+предмет: Пон II/1 Математика 5А', true,  a, 1, 2, 1, 'Математика', '12', array['5А']);
  -- 3: един и същ клас в двата слота (друг учител)
  perform pg_temp.try_save('3 клас: 8А в Пон II/1', true, b, 1, 2, 1, 'Физика', '', array['8А']);
  -- 4: групов предмет
  perform pg_temp.try_save('4 група: ТЕСТГРУПА 9А I/7 К1', true, a, 2, 1, 7, 'ТЕСТГРУПА', 'К1', array['9А']);
  perform pg_temp.try_save('4 група: ТЕСТГРУПА 9А I/7 К2', true, b, 2, 1, 7, 'ТЕСТГРУПА', 'К2', array['9А']);
  perform pg_temp.try_save('4 група: ТЕСТГРУПА 9А II/1 К1 (не е блокирана от I/7)', true, c, 2, 2, 1, 'ТЕСТГРУПА', 'К1', array['9А']);
  perform pg_temp.try_save('4 група: ТЕСТГРУПА 9А II/1 К2', true, a, 2, 2, 1, 'ТЕСТГРУПА', 'К2', array['9А']);
  -- 5: реален конфликт в същата клетка
  perform pg_temp.try_save('5 конфликт: същ учител, Пон I/7', false, a, 1, 1, 7, 'Физика', '', array['10А']);
  perform pg_temp.try_save('5 конфликт: същ клас 8А, Пон I/7', false, c, 1, 1, 7, 'Физика', '', array['8А']);
  perform pg_temp.try_save('5 конфликт: трета група 9А I/7', false, c, 2, 1, 7, 'ТЕСТГРУПА', 'К3', array['9А']);
  -- 6: обратна посока (първо II/1, после I/7), нови потребител/ден
  perform pg_temp.try_save('6 обратно: първо II/1 Вторник... Сряда II/1', true, c, 3, 2, 1, 'Математика', '12', array['6А']);
  perform pg_temp.try_save('6 обратно: после Сряда I/7 (същ учител/предмет/място)', true, c, 3, 1, 7, 'Математика', '12', array['11А']);
  -- запис се пази като подаден (без канонизиране на II/1 -> I/7)
  insert into res select '7 II/1 е записан като shift=2,hour=1', exists (
      select 1 from public.consultations where teacher_id = a and day = 1 and shift = 2 and hour = 1), '';
  insert into res select '8 няма slot_of', not exists (select 1 from pg_proc where proname = 'slot_of'), '';
  insert into res select '9 индексът е (teacher_id, day, shift, hour)',
      (select indexdef like '%(teacher_id, day, shift, hour)%' from pg_indexes where indexname = 'consultations_teacher_slot_uq'), '';
end $$;

select test, ok, detail from res order by 1;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from res;
rollback;
