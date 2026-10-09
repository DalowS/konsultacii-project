-- Проверка v2.6 на Supabase SQL Editor; всички промени се отменят с ROLLBACK.
-- Тества директния RPC save_consultation, включително двете конфигурации на редовните смени.
begin;

create temp table res(test text, ok boolean, detail text) on commit drop;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
end $$;

create or replace function pg_temp.expect_err(p_name text, p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    insert into res values (p_name, false, 'очаквана грешка, но няма');
  exception when others then
    insert into res values (p_name, sqlerrm like '%' || p_like || '%', sqlerrm);
  end;
end $$;

create or replace function pg_temp.expect_ok(p_name text, p_sql text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    insert into res values (p_name, true, '');
  exception when others then
    insert into res values (p_name, false, sqlerrm);
  end;
end $$;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  c_gym text;
  c_prog text;
  shifts jsonb;
begin
  insert into auth.users (id, email, raw_user_meta_data) values
    (a, 'v26-a@example.invalid', '{"name":"ТЕСТ v2.6 А"}'),
    (b, 'v26-b@example.invalid', '{"name":"ТЕСТ v2.6 Б"}');

  -- 5А не е задължително да е предварително създаден; новият тестов ред се отменя с ROLLBACK.
  insert into public.classes (name) values ('5А') on conflict (name) do nothing;
  select name into c_gym from public.classes where name = '8А';
  select name into c_prog from public.classes where name = '5А';
  if c_gym is null or c_prog is null then
    raise exception 'За SQL проверката са необходими класове 5А и 8А.';
  end if;

  shifts := public.get_consultation_stage_shifts();
  insert into res values ('Начална конфигурация: гимназия I, прогимназия II',
    shifts->>'gymnasium' = '1' and shifts->>'progymnasium' = '2', shifts::text);

  perform pg_temp.as_user(a);
  -- I/7 и II/1 имат еднакъв физически етикет, но са независими слотове.
  -- Различните класове са от двата етапа, затова и двете консултационни смени са допустими.
  perform pg_temp.expect_ok('Гимназия: II/1 е допустима (редовна I)',
    format($f$select public.save_consultation(null,1,2,1,'Математика','Каб. 12',array[%L])$f$, c_gym));
  perform pg_temp.expect_ok('Прогимназия: I/7 е допустима (редовна II), същият учител/предмет/място',
    format($f$select public.save_consultation(null,1,1,7,'Математика','Каб. 12',array[%L])$f$, c_prog));
  perform pg_temp.expect_err('Гимназия: I смяна се отказва',
    format($f$select public.save_consultation(null,2,1,1,'Физика','',array[%L])$f$, c_gym), 'само в II смяна');
  perform pg_temp.expect_err('Прогимназия: II смяна се отказва',
    format($f$select public.save_consultation(null,2,2,1,'Физика','',array[%L])$f$, c_prog), 'само в I смяна');
  perform pg_temp.expect_err('Смесени етапи се отказват',
    format($f$select public.save_consultation(null,2,2,2,'Физика','',array[%L,%L])$f$, c_gym, c_prog), 'само от един етап');
  perform pg_temp.expect_err('Час 8 се отказва',
    format($f$select public.save_consultation(null,2,2,8,'Физика','',array[%L])$f$, c_gym), 'Невалиден ден, смяна или час');

  -- Проверява обратната конфигурация в същата транзакция; ROLLBACK възстановява началната.
  update public.consultation_stage_shifts set regular_shift = 2 where stage = 'gymnasium';
  update public.consultation_stage_shifts set regular_shift = 1 where stage = 'progymnasium';
  shifts := public.get_consultation_stage_shifts();
  insert into res values ('Обратна конфигурация: гимназия II, прогимназия I',
    shifts->>'gymnasium' = '2' and shifts->>'progymnasium' = '1', shifts::text);

  perform pg_temp.as_user(b);
  perform pg_temp.expect_ok('Гимназия: I/1 е допустима (редовна II)',
    format($f$select public.save_consultation(null,3,1,1,'История','Каб. 3',array[%L])$f$, c_gym));
  perform pg_temp.expect_ok('Прогимназия: II/7 е допустима (редовна I)',
    format($f$select public.save_consultation(null,3,2,7,'История','Каб. 3',array[%L])$f$, c_prog));
  perform pg_temp.expect_err('Гимназия: II смяна се отказва при обратна конфигурация',
    format($f$select public.save_consultation(null,4,2,1,'БЕЛ','',array[%L])$f$, c_gym), 'само в I смяна');
  perform pg_temp.expect_err('Прогимназия: I смяна се отказва при обратна конфигурация',
    format($f$select public.save_consultation(null,4,1,1,'БЕЛ','',array[%L])$f$, c_prog), 'само в II смяна');
end $$;

select * from res order by test;
rollback;
