-- =====================================================================
-- РЪЧНА ПРОВЕРКА след миграция 20261008000000_independent_shifts.sql (Supabase SQL Editor).
-- Работи в транзакция и накрая прави ROLLBACK -> нищо не се записва.
-- Създава временни auth потребители (A, B, C) и имитира JWT чрез request.jwt.claims.
-- Резултатът е таблица "резултати" (ok = true/false). ТОЗИ СКРИПТ НЕ Е ИЗПЪЛНЯВАН ОТ АВТОРА.
-- =====================================================================
begin;

create temp table res(test text, ok boolean, detail text) on commit drop;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
end $$;

-- очаква грешка, съдържаща текст
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
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid(); d uuid := gen_random_uuid();
  adm uuid; c1 text; c2 text; n int; v_cls bigint;
begin
  -- временни потребители (handle_new_user ще създаде teachers редове)
  insert into auth.users (id, email, raw_user_meta_data) values
    (a, 'tmp-a@example.invalid', '{"name":"ТЕСТ А"}'),
    (b, 'tmp-b@example.invalid', '{"name":"ТЕСТ Б"}'),
    (c, 'tmp-c@example.invalid', '{"name":"ТЕСТ В"}'),
    (d, 'tmp-d@example.invalid', '{"name":"ТЕСТ Г"}');
  select id into adm from public.teachers where role = 'admin' limit 1;
  select name into c1 from public.classes order by id limit 1;
  select name into c2 from public.classes order by id offset 1 limit 1;

  insert into public.group_subjects(subject, enabled) values ('ТЕСТГРУПА', true) on conflict (subject) do update set enabled = true;

  -- ===== 12:35-13:15: I смяна/7 и II смяна/1 са НЕЗАВИСИМИ клетки =====
  perform pg_temp.as_user(a);
  perform pg_temp.expect_ok('A: I смяна/7 (12:35) - ' || c1,
    format($f$select public.save_consultation(null,1,1,7,'Математика','Каб. 12',array[%L])$f$, c1));
  perform pg_temp.expect_ok('A: II смяна/1 (12:35) СЪЩИЯ ден, същия предмет, същите класове, същото място = РАЗРЕШЕНО',
    format($f$select public.save_consultation(null,1,2,1,'Математика','Каб. 12',array[%L])$f$, c1));
  select count(*) into n from public.consultations where teacher_id = a and day = 1 and shift = 1 and hour = 7;
  insert into res values ('A има запис в (I,7)', n = 1, 'редове: ' || n);
  select count(*) into n from public.consultations where teacher_id = a and day = 1 and shift = 2 and hour = 1;
  insert into res values ('A има запис в (II,1) – не е превърнат в (I,7)', n = 1, 'редове: ' || n);

  -- нормалните конфликти В РАМКИТЕ НА СЪЩАТА клетка остават
  perform pg_temp.expect_err('A: втора консултация в същата клетка (I,7) = КОНФЛИКТ на учителя',
    format($f$select public.save_consultation(null,1,1,7,'Физика','',array[%L])$f$, c2), 'друга консултация');
  perform pg_temp.expect_err('A: втора консултация в същата клетка (II,1) = КОНФЛИКТ на учителя',
    format($f$select public.save_consultation(null,1,2,1,'Физика','',array[%L])$f$, c2), 'друга консултация');
  perform pg_temp.as_user(b);
  perform pg_temp.expect_err('B: клас ' || c1 || ' в (I,7) вече е зает от A = КОНФЛИКТ на клас',
    format($f$select public.save_consultation(null,1,1,7,'Химия','',array[%L])$f$, c1), 'вече има консултация');
  perform pg_temp.expect_err('B: клас ' || c1 || ' в (II,1) вече е зает от A = КОНФЛИКТ на клас',
    format($f$select public.save_consultation(null,1,2,1,'Химия','',array[%L])$f$, c1), 'вече има консултация');
  perform pg_temp.expect_ok('B: друг клас в (I,7) и (II,1) – независимо',
    format($f$select public.save_consultation(null,1,1,7,'Химия','',array[%L])$f$, c2));
  perform pg_temp.expect_ok('B: същият учител, другата смяна, 12:35',
    format($f$select public.save_consultation(null,1,2,1,'Химия','',array[%L])$f$, c2));
  perform pg_temp.expect_err('час 8 е невалиден',
    format($f$select public.save_consultation(null,3,1,8,'Тест6','',array[%L])$f$, c1), 'Невалиден');
  select count(*) into n from public.consultations where teacher_id in (a, b) and day = 1;
  insert into res values ('общо 4 записа (по 2 за A и B)', n = 4, 'редове: ' || n);

  -- ===== паралелни групи: само в рамките на клетката =====
  perform pg_temp.as_user(a);
  perform pg_temp.expect_ok('група 1 в (I,7), място К1',
    format($f$select public.save_consultation(null,4,1,7,'ТЕСТГРУПА','К1',array[%L])$f$, c1));
  perform pg_temp.as_user(c);
  perform pg_temp.expect_ok('група 2 в (I,7), място К2',
    format($f$select public.save_consultation(null,4,1,7,'ТЕСТГРУПА','К2',array[%L])$f$, c1));
  perform pg_temp.as_user(d);
  perform pg_temp.expect_err('група 3 в (I,7) = отказ (най-много две)',
    format($f$select public.save_consultation(null,4,1,7,'ТЕСТГРУПА','К3',array[%L])$f$, c1), 'две групи');
  perform pg_temp.expect_ok('група в (II,1) със същото място К1 – (I,7) НЕ влияе на (II,1)',
    format($f$select public.save_consultation(null,4,2,1,'ТЕСТГРУПА','К1',array[%L])$f$, c1));

  -- ===== права =====
  perform pg_temp.as_user(c);
  perform pg_temp.expect_err('C не може да редактира чужд запис',
    format($f$select public.save_consultation((select id from public.consultations where teacher_id=%L and day=1 limit 1),1,1,6,'Х','',array[%L])$f$, a, c1),
    'право');

  -- ===== класове (като админ) =====
  perform pg_temp.as_user(adm);
  perform pg_temp.expect_ok('admin_add_class(5, латинско A) -> 5А', $f$select public.admin_add_class(5, 'A')$f$);
  perform pg_temp.expect_err('дубликат (кирилско А)', format($f$select public.admin_add_class(5, %L)$f$, chr(1040)), 'вече съществува');
  perform pg_temp.expect_err('клас 13', $f$select public.admin_add_class(13, 'А')$f$, 'от 5 до 12');
  perform pg_temp.expect_err('клас 4 (извън етапите)', $f$select public.admin_add_class(4, 'А')$f$, 'от 5 до 12');
  perform pg_temp.expect_err('малка буква', $f$select public.admin_add_class(6, 'а')$f$, 'главна буква');
  perform pg_temp.as_user(a);
  perform pg_temp.expect_err('учител не може да добавя клас', $f$select public.admin_add_class(7, 'А')$f$, 'администратор');
  perform pg_temp.as_user(adm);
  perform pg_temp.expect_err('клас с консултации не се трие',
    format($f$delete from public.classes where name = %L$f$, c1), 'не може да бъде изтрит');
  perform pg_temp.expect_ok('празен клас се трие (5А)', $f$delete from public.classes where name = '5А'$f$);

  -- ===== премахване на учител =====
  perform pg_temp.expect_err('admin не може да изтрие себе си', format($f$select public.admin_delete_teacher(%L)$f$, adm), 'собствения');
  perform pg_temp.as_user(a);
  perform pg_temp.expect_err('учител не може да трие учители', format($f$select public.admin_delete_teacher(%L)$f$, b), 'администратор');
  perform pg_temp.as_user(adm);
  perform pg_temp.expect_ok('admin трие учител B', format($f$select public.admin_delete_teacher(%L)$f$, b));
  select count(*) into n from auth.users where id = b;
  insert into res values ('Auth акаунтът на B е изтрит', n = 0, 'auth.users: ' || n);
  select count(*) into n from public.teachers where id = b;
  insert into res values ('teachers редът на B е изтрит', n = 0, 'teachers: ' || n);
  select count(*) into n from public.consultations where teacher_id = b;
  insert into res values ('консултациите на B са изтрити', n = 0, 'консултации: ' || n);
  select count(*) into n from public.consultations where teacher_id = a;
  insert into res values ('консултациите на A са запазени', n > 0, 'консултации: ' || n);
end $$;

select * from res order by ok, test;   -- всички редове трябва да са ok = true
rollback;
