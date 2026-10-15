-- =====================================================================
-- v2.9: ръчна/автоматична проверка на миграция 20261010000000_school_settings_users_domain.sql
-- Транзакция с ROLLBACK. Резултат: таблица (test, ok, detail) + брой.
-- Роли се имитират с `set local role authenticated|anon` + request.jwt.claims.
-- Изпълнявайте като собственик (SQL Editor на Supabase / psql), СЛЕД всички миграции.
-- =====================================================================
begin;
create temp table res(test text, ok boolean, detail text);
grant all on res to public;

create or replace function pg_temp.exp_err(p_name text, p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin execute p_sql; insert into res values (p_name, false, 'очаквана грешка, но няма');
  exception when others then insert into res values (p_name, sqlerrm like '%' || p_like || '%', sqlerrm); end;
end $$;
create or replace function pg_temp.exp_ok(p_name text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; insert into res values (p_name, true, '');
  exception when others then insert into res values (p_name, false, sqlerrm); end;
end $$;
grant execute on function pg_temp.exp_err(text,text,text), pg_temp.exp_ok(text,text) to public;

do $$
declare adm uuid := gen_random_uuid(); tch uuid := gen_random_uuid(); n int; v text;
begin
  -- ---- домейн на имейла (на ниво база, trigger върху auth.users) ----
  perform pg_temp.exp_ok ('имейл @paisii.info се приема',                         $q$insert into auth.users(id,email) values (gen_random_uuid(),'ivan@paisii.info')$q$);
  perform pg_temp.exp_ok ('имейл с главни и интервали (нормализира се)',          $q$insert into auth.users(id,email) values (gen_random_uuid(),'  Maria@PAISII.info ')$q$);
  perform pg_temp.exp_err('@gmail.com се отказва',                                $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@gmail.com')$q$, '@paisii.info');
  perform pg_temp.exp_err('@abv.bg се отказва',                                   $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@abv.bg')$q$, '@paisii.info');
  perform pg_temp.exp_err('@yahoo.com се отказва',                                $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@yahoo.com')$q$, '@paisii.info');
  perform pg_temp.exp_err('@outlook.com се отказва',                              $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@outlook.com')$q$, '@paisii.info');
  perform pg_temp.exp_err('x@paisii.info.evil.com се отказва',                    $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@paisii.info.evil.com')$q$, '@paisii.info');
  perform pg_temp.exp_err('x@evilpaisii.info се отказва',                         $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@evilpaisii.info')$q$, '@paisii.info');
  perform pg_temp.exp_err('x@sub.paisii.info се отказва',                         $q$insert into auth.users(id,email) values (gen_random_uuid(),'x@sub.paisii.info')$q$, '@paisii.info');
  perform pg_temp.exp_err('"a@gmail.com@paisii.info" се отказва',                 $q$insert into auth.users(id,email) values (gen_random_uuid(),'a b@paisii.info')$q$, '@paisii.info');
  perform pg_temp.exp_err('празен локален дел (@paisii.info) се отказва',         $q$insert into auth.users(id,email) values (gen_random_uuid(),'@paisii.info')$q$, '@paisii.info');
  perform pg_temp.exp_err('липсващ имейл (null) се отказва',                      $q$insert into auth.users(id,email) values (gen_random_uuid(),null)$q$, '@paisii.info');

  -- профил (teachers) се създава автоматично за приетите
  select count(*) into n from public.teachers where name in ('ivan@paisii.info', 'Maria@PAISII.info', '  Maria@PAISII.info');
  insert into res values ('handle_new_user създава профили за приетите регистрации', n >= 1, 'teachers: ' || n);

  -- смяна на имейл към чужд домейн; без смяна на имейл – позволено
  insert into auth.users(id,email,email_confirmed_at) values (tch,'teacher@paisii.info',now()), (adm,'admin@paisii.info',now());
  alter table public.teachers disable trigger teachers_protect_role;
  update public.teachers set role = 'admin', name = 'Мария Петрова' where id = adm;
  update public.teachers set name = 'Георги Иванов' where id = tch;
  alter table public.teachers enable trigger teachers_protect_role;
  perform pg_temp.exp_err('смяна на имейл към @gmail.com се отказва', format($q$update auth.users set email='t@gmail.com' where id=%L$q$, tch), '@paisii.info');
  perform pg_temp.exp_ok ('промяна на друго поле (без имейл) е позволена', format($q$update auth.users set banned_until = null where id=%L$q$, tch));

  -- ---- school_settings: RLS ----
  select count(*) into n from public.school_settings;
  insert into res values ('има точно един ред с настройки (seed)', n = 1, 'редове: ' || n);

  perform set_config('request.jwt.claims', json_build_object('sub', tch, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.exp_ok ('teacher чете настройките (SELECT)',                  $q$select school_name, academic_year, current_term from public.school_settings$q$);
  perform pg_temp.exp_err('teacher не може UPDATE директно',                    $q$update public.school_settings set school_name='X'$q$, 'permission denied');
  perform pg_temp.exp_err('teacher не може INSERT директно',                    $q$insert into public.school_settings(id,school_name,academic_year,current_term) values (2,'X','2026/2027','I')$q$, 'permission denied');
  perform pg_temp.exp_err('teacher не може DELETE директно',                    $q$delete from public.school_settings$q$, 'permission denied');
  perform pg_temp.exp_err('teacher не може RPC admin_update_school_settings',   $q$select public.admin_update_school_settings('X','2026/2027','I')$q$, 'Само администратор');
  perform pg_temp.exp_err('teacher не може admin_list_users()',                 $q$select * from public.admin_list_users()$q$, 'Само администратор');

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.exp_err('и admin няма директен UPDATE (само през RPC)',       $q$update public.school_settings set school_name='X'$q$, 'permission denied');
  perform pg_temp.exp_ok ('admin: RPC записва име, година, срок',               $q$select public.admin_update_school_settings('СУ „Св. Паисий Хилендарски“ – Пловдив','2027/2028','II')$q$);
  perform pg_temp.exp_err('admin: година 2026/2028 се отказва',                 $q$select public.admin_update_school_settings('X','2026/2028','I')$q$, 'последователни');
  perform pg_temp.exp_err('admin: година 2026-2027 се отказва',                 $q$select public.admin_update_school_settings('X','2026-2027','I')$q$, '2026/2027');
  perform pg_temp.exp_err('admin: срок III се отказва',                         $q$select public.admin_update_school_settings('X','2026/2027','III')$q$, 'I или II');
  perform pg_temp.exp_err('admin: празно име се отказва',                       $q$select public.admin_update_school_settings('   ','2026/2027','I')$q$, 'име на училището');
  perform pg_temp.exp_err('admin: име над 150 символа се отказва',              format($q$select public.admin_update_school_settings(%L,'2026/2027','I')$q$, repeat('а',151)), 'име на училището');
  select school_name || '|' || academic_year || '|' || current_term into v from public.school_settings;
  insert into res values ('записаните стойности се четат обратно', v = 'СУ „Св. Паисий Хилендарски“ – Пловдив|2027/2028|II', v);
  insert into res select 'admin_list_users: имейл, роля, статус, дата', count(*) filter (where email = 'admin@paisii.info' and role = 'admin' and status = 'active' and created_at is not null) = 1, 'редове: ' || count(*) from public.admin_list_users();
  reset role;

  -- един ред: втори ред е невъзможен и за собственик
  perform pg_temp.exp_err('втори ред в school_settings е невъзможен (id=1)', $q$insert into public.school_settings(id,school_name,academic_year,current_term) values (2,'X','2026/2027','I')$q$, 'single_row');

  -- блокиран / непотвърден статус
  update auth.users set banned_until = now() + interval '1 day' where id = tch;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into res select 'admin_list_users: blocked статус', status = 'blocked', status from public.admin_list_users() where id = tch;
  reset role;

  -- anon
  set local role anon;
  perform pg_temp.exp_err('anon не чете school_settings', $q$select * from public.school_settings$q$, 'permission denied');
  perform pg_temp.exp_err('anon не вика admin_list_users', $q$select * from public.admin_list_users()$q$, 'permission denied');
  reset role;
end $$;

select test, ok, detail from res order by 1;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from res;
rollback;
