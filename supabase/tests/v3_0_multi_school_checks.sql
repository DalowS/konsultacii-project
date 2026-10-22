-- =====================================================================
-- v3.0: проверки на многоучилищната система (миграции 20261012 – 20261014)
-- Изпълнява се СЛЕД трите миграции, като собственик (psql / SQL Editor), в ТРАНЗАКЦИЯ С ROLLBACK
-- (нищо не остава в базата). Резултат: таблица (test, ok, detail) + брой.
-- Роли се имитират с `set local role authenticated` + request.jwt.claims.
-- ВНИМАНИЕ: пускайте само на ТЕСТОВА/локална база – тестът създава записи (с rollback), но не е
-- предназначен за продукционна база.
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
create or replace function pg_temp.chk(p_name text, p_cond boolean, p_detail text default '') returns void language plpgsql as $$
begin insert into res values (p_name, coalesce(p_cond, false), p_detail); end $$;
create or replace function pg_temp.act(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.unact() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create or replace function pg_temp.cnt(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute p_sql into n; return n; end $$;
grant execute on function pg_temp.exp_err(text,text,text), pg_temp.exp_ok(text,text), pg_temp.chk(text,boolean,text),
  pg_temp.act(uuid), pg_temp.unact(), pg_temp.cnt(text) to public;

-- ---------- Данни за теста (като собственик) ---------------------------------------------
-- A = първоначалното училище (домейн paisii.info); B и C – нови
do $$
declare
  A constant uuid := '00000000-0000-4000-8000-000000000001';
  B constant uuid := '00000000-0000-4000-8000-0000000000b0';
  C constant uuid := '00000000-0000-4000-8000-0000000000c0';
begin
  insert into public.schools (id, name) values (B, 'Тест училище Б'), (C, 'Тест училище В');
  insert into public.school_settings (school_id, school_name, academic_year, current_term)
  values (B, 'Тест училище Б', '2026/2027', 'I'), (C, 'Тест училище В', '2026/2027', 'I');
  insert into public.school_email_domains (school_id, domain) values (B, 'school-b.bg'), (C, 'school-c.bg');
  insert into public.school_email_domains (school_id, domain, allow_subdomains) values (C, 'sub-c.bg', true);

  insert into public.classes (name, school_id) values ('5А', A), ('5Б', A) on conflict do nothing;
  insert into public.classes (name, school_id) values ('5А', B), ('5Б', B), ('5Г', B), ('5А', C);

  -- потребители чрез Auth (trigger -> профил + членство)
  insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
    ('00000000-0000-0000-0000-00000000a001', 'v3admin.a@paisii.info', '{"name":"Админ А"}', now()),
    ('00000000-0000-0000-0000-00000000a002', 'v3teacher1.a@paisii.info', '{"name":"Учител А1"}', now()),
    ('00000000-0000-0000-0000-00000000a003', 'v3teacher2.a@paisii.info', '{"name":"Учител А2"}', now()),
    ('00000000-0000-0000-0000-00000000b001', 'v3admin.b@school-b.bg', '{"name":"Админ Б"}', now()),
    ('00000000-0000-0000-0000-00000000b002', 'v3teacher.b@school-b.bg', '{"name":"Учител Б"}', now()),
    ('00000000-0000-0000-0000-00000000c002', 'v3teacher.c@school-c.bg', '{"name":"Учител В"}', now()),
    ('00000000-0000-0000-0000-000000005001', 'v3super@paisii.info', '{"name":"Супер Админ"}', now());
  -- роли: само чрез членство (както би го направил администратор/SQL Editor)
  update public.school_memberships set role = 'admin'
   where user_id in ('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000b001');
  insert into public.super_admins (user_id, note) values ('00000000-0000-0000-0000-000000005001', 'тест');
end $$;

-- ---------- 1. Регистрация по домейн ------------------------------------------------------
do $$
declare n int; v text; v_role text; v_school uuid;
begin
  select m.role, m.school_id into v_role, v_school from public.school_memberships m
   where m.user_id = '00000000-0000-0000-0000-00000000a002';
  perform pg_temp.chk('регистрация @paisii.info -> училище А, роля teacher', v_role = 'teacher' and v_school = '00000000-0000-4000-8000-000000000001', v_role);
  select t.school_id::text into v from public.teachers t where t.id = '00000000-0000-0000-0000-00000000b002';
  perform pg_temp.chk('регистрация @school-b.bg -> училище Б', v = '00000000-0000-4000-8000-0000000000b0', v);

  perform pg_temp.exp_ok ('имейл с главни букви и интервали се нормализира (А)',    $q$insert into auth.users(id,email) values (gen_random_uuid(),'  V3Norm@PAISII.info ')$q$);
  perform pg_temp.exp_err('x@gmail.com се отказва',                                $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@gmail.com')$q$, 'домейн');
  perform pg_temp.exp_err('x@paisii.info.evil.com се отказва (lookalike)',         $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@paisii.info.evil.com')$q$, 'домейн');
  perform pg_temp.exp_err('x@evilpaisii.info се отказва (lookalike)',              $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@evilpaisii.info')$q$, 'домейн');
  perform pg_temp.exp_err('x@sub.paisii.info се отказва (поддомейн не е разрешен)', $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@sub.paisii.info')$q$, 'домейн');
  perform pg_temp.exp_err('имейл с интервал в локалната част се отказва',          $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3 x@paisii.info')$q$, 'домейн');
  perform pg_temp.exp_err('липсващ имейл се отказва',                              $q$insert into auth.users(id,email) values (gen_random_uuid(),null)$q$, 'домейн');
  perform pg_temp.exp_err('кирилски lookalike домейн се отказва',                  $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@раisii.info')$q$, 'домейн');

  -- метаданни не могат да дадат роля/училище
  insert into auth.users(id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-00000000a0f0','v3meta@paisii.info','{"name":"Хакер","role":"admin","school_id":"00000000-0000-4000-8000-0000000000b0"}');
  select m.role || '/' || m.school_id into v from public.school_memberships m where m.user_id = '00000000-0000-0000-0000-00000000a0f0';
  perform pg_temp.chk('публична регистрация = teacher и училище само по домейн (metadata се игнорира)',
    v = 'teacher/00000000-0000-4000-8000-000000000001', v);

  -- поддомейни: само ако са разрешени изрично
  perform pg_temp.exp_ok ('mail.sub-c.bg се приема (allow_subdomains)',            $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@mail.sub-c.bg')$q$);
  perform pg_temp.exp_err('x@evilsub-c.bg се отказва',                             $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@evilsub-c.bg')$q$, 'домейн');
  perform pg_temp.exp_err('x@mail.school-c.bg се отказва (поддомейни не са разрешени)', $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@mail.school-c.bg')$q$, 'домейн');

  -- двусмислен домейн (активен в две активни училища)
  insert into public.school_email_domains (school_id, domain) values
    ('00000000-0000-4000-8000-0000000000b0', 'shared-test.bg'), ('00000000-0000-4000-8000-0000000000c0', 'shared-test.bg');
  perform pg_temp.exp_err('двусмислен домейн -> регистрацията се отказва',       $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@shared-test.bg')$q$, 'повече от едно училище');
  insert into public.school_invites (school_id, email) values ('00000000-0000-4000-8000-0000000000b0', 'v3invited@shared-test.bg');
  insert into auth.users(id,email) values ('00000000-0000-0000-0000-00000000b0f1','v3invited@shared-test.bg');
  select m.school_id::text into v from public.school_memberships m where m.user_id = '00000000-0000-0000-0000-00000000b0f1';
  perform pg_temp.chk('покана решава двусмислен домейн -> училище Б', v = '00000000-0000-4000-8000-0000000000b0', v);
  select status into v from public.school_invites where email = 'v3invited@shared-test.bg';
  perform pg_temp.chk('поканата се маркира като използвана', v = 'used', v);

  -- деактивиран домейн / неактивно училище
  update public.school_email_domains set active = false where domain = 'school-c.bg';
  perform pg_temp.exp_err('деактивиран домейн се отказва',                         $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@school-c.bg')$q$, 'домейн');
  update public.school_email_domains set active = true where domain = 'school-c.bg';
  update public.schools set status = 'inactive' where id = '00000000-0000-4000-8000-0000000000c0';
  perform pg_temp.exp_err('неактивно училище -> регистрацията се отказва',         $q$insert into auth.users(id,email) values (gen_random_uuid(),'v3x@school-c.bg')$q$, 'не е активно');
  update public.schools set status = 'active' where id = '00000000-0000-4000-8000-0000000000c0';

  -- смяна на имейл
  perform pg_temp.exp_err('смяна на имейл към домейн на друго училище се отказва', $q$update auth.users set email='v3teacher1.a@school-b.bg' where id='00000000-0000-0000-0000-00000000a002'$q$, 'училище');
  perform pg_temp.exp_ok ('смяна на имейл в рамките на същия домейн е позволена',  $q$update auth.users set email='v3teacher1new.a@paisii.info' where id='00000000-0000-0000-0000-00000000a002'$q$);
end $$;

-- ---------- 2. Изолация на данните между училищата -------------------------------------------
do $$
declare
  A constant uuid := '00000000-0000-4000-8000-000000000001';
  B constant uuid := '00000000-0000-4000-8000-0000000000b0';
  v_id bigint; v_cid_a bigint; n bigint;
begin
  -- учител А създава консултация със „5А“ (клас, който съществува и в Б, и във В)
  perform pg_temp.act('00000000-0000-0000-0000-00000000a002');
  v_id := public.save_consultation(null, 1, 1, 3, 'Математика v3', 'каб. А', array['5А']);
  perform pg_temp.unact();
  select count(*) into n from public.consultation_classes cc join public.classes k on k.id = cc.class_id
   where cc.consultation_id = v_id and k.school_id = A and cc.school_id = A;
  perform pg_temp.chk('консултацията на А се връзва с класа „5А“ на училище А', n = 1, n::text);
  perform pg_temp.chk('consultations.school_id е на учителя', (select school_id from public.consultations where id = v_id) = A);

  -- учител Б създава в същия слот със същия клас: независимо от А
  perform pg_temp.act('00000000-0000-0000-0000-00000000b002');
  perform pg_temp.exp_ok('учител Б: същият слот/име на клас в друго училище не е конфликт',
    $q$select public.save_consultation(null, 1, 1, 3, 'Математика Б', 'каб. Б', array['5А'])$q$);
  perform pg_temp.chk('учител Б вижда само данните на Б (консултации)',
    pg_temp.cnt('select count(*) from public.consultations') = pg_temp.cnt('select count(*) from public.consultations where school_id = ''' || B || ''''));
  perform pg_temp.chk('учител Б вижда само класовете на Б', pg_temp.cnt('select count(*) from public.classes') = 3);
  perform pg_temp.chk('учител Б вижда само учителите на Б', pg_temp.cnt('select count(*) from public.teachers where school_id <> ''' || B || '''') = 0);
  perform pg_temp.chk('учител Б вижда само своето училище (schools)', pg_temp.cnt('select count(*) from public.schools') = 1);
  perform pg_temp.chk('учител Б не вижда домейни', pg_temp.cnt('select count(*) from public.school_email_domains') = 0);
  perform pg_temp.chk('учител Б не вижда членства на други', pg_temp.cnt('select count(*) from public.school_memberships where user_id <> auth.uid()') = 0);
  perform pg_temp.chk('учител Б не вижда настройките на А', pg_temp.cnt('select count(*) from public.school_settings where school_id <> ''' || B || '''') = 0);
  perform pg_temp.chk('учител Б не вижда графика на А', pg_temp.cnt('select count(*) from public.school_intervals where school_id <> ''' || B || '''') = 0);
  perform pg_temp.exp_err('учител Б не може да запише в клас от А (само клас „5Г“ има в Б; „5В“ няма никъде)',
    $q$select public.save_consultation(null, 2, 1, 3, 'Х', 'к', array['5В'])$q$, 'Невалиден избор на клас');
  perform pg_temp.exp_ok('учител Б използва клас „5Г“ (уникален за Б)', $q$select public.save_consultation(null, 2, 1, 3, 'Х', 'к', array['5Г'])$q$);
  perform pg_temp.exp_err('учител Б не може да редактира консултация на А', format($q$select public.save_consultation(%s, 1, 1, 4, 'Х', 'к', array['5А'])$q$, v_id), 'не е намерен');
  perform pg_temp.exp_err('учител Б: директен UPDATE на consultations е забранен', format($q$update public.consultations set subject='ХАК' where id=%s$q$, v_id), 'permission denied');
  perform pg_temp.unact();
end $$;

do $$
declare
  A constant uuid := '00000000-0000-4000-8000-000000000001';
  B constant uuid := '00000000-0000-4000-8000-0000000000b0';
  v_id bigint; n bigint;
begin
  select c.id into v_id from public.consultations c where c.school_id = A and c.subject = 'Математика v3';
  perform pg_temp.act('00000000-0000-0000-0000-00000000b002');
  -- директно изтриване на чужда консултация (RLS -> 0 реда)
  delete from public.consultations where id = v_id;
  get diagnostics n = row_count;
  perform pg_temp.unact();
  perform pg_temp.chk('учител Б не може да изтрие консултация на А', n = 0, n::text);

  perform pg_temp.act('00000000-0000-0000-0000-00000000a003');
  delete from public.consultations where id = v_id;
  get diagnostics n = row_count;
  perform pg_temp.unact();
  perform pg_temp.chk('учител А2 не може да изтрие консултация на колега А1', n = 0, n::text);

  perform pg_temp.act('00000000-0000-0000-0000-00000000a002');
  perform pg_temp.exp_err('учител: директен INSERT в consultations',  $q$insert into public.consultations(teacher_id,day,shift,hour,subject) values (auth.uid(),1,1,5,'х')$q$, 'permission denied');
  perform pg_temp.exp_err('учител: директен INSERT в classes',        $q$insert into public.classes(name) values ('9Я')$q$, 'permission denied');
  perform pg_temp.exp_err('учител: директен INSERT в schools',        $q$insert into public.schools(name) values ('Хак')$q$, 'permission denied');
  perform pg_temp.exp_err('учител: директен INSERT в school_memberships', $q$insert into public.school_memberships(user_id,school_id,role) values (auth.uid(),'00000000-0000-4000-8000-0000000000b0','admin')$q$, 'permission denied');
  perform pg_temp.exp_err('учител: директен INSERT в super_admins',   $q$insert into public.super_admins(user_id) values (auth.uid())$q$, 'permission denied');
  perform pg_temp.exp_err('учител: UPDATE на role в teachers',        $q$update public.teachers set role='admin' where id=auth.uid()$q$, 'permission denied');
  perform pg_temp.exp_err('учител: UPDATE на school_id в teachers',   $q$update public.teachers set school_id='00000000-0000-4000-8000-0000000000b0' where id=auth.uid()$q$, 'permission denied');
  perform pg_temp.exp_err('учител: UPDATE на membership.role',        $q$update public.school_memberships set role='admin' where user_id=auth.uid()$q$, 'permission denied');
  perform pg_temp.exp_ok ('учител: смяна на собственото име',         $q$update public.teachers set name='Учител А1 (ново)' where id=auth.uid()$q$);
  perform pg_temp.exp_err('учител: не може school_settings UPDATE',   $q$update public.school_settings set school_name='Х'$q$, 'permission denied');
  perform pg_temp.exp_err('учител: admin_add_class',                  $q$select public.admin_add_class(7, 'А')$q$, 'администратор');
  perform pg_temp.exp_err('учител: admin_set_member_role',            format($q$select public.admin_set_member_role(%L, 'admin')$q$, '00000000-0000-0000-0000-00000000a003'), 'администратор');
  perform pg_temp.exp_err('учител: admin_add_domain',                 $q$select public.admin_add_domain('x.bg')$q$, 'право');
  perform pg_temp.exp_err('учител: super_list_schools',               $q$select * from public.super_list_schools()$q$, 'супер администратор');
  perform pg_temp.exp_err('учител: set_active_school',                $q$select public.set_active_school('00000000-0000-4000-8000-0000000000b0')$q$, 'супер администратор');
  perform pg_temp.exp_err('учител: super_create_school',              $q$select public.super_create_school('Хак')$q$, 'супер администратор');
  perform pg_temp.exp_err('учител: admin_set_schedule_mode',          $q$select public.admin_set_schedule_mode('one_shift')$q$, 'администратор');
  perform pg_temp.exp_err('учител: admin_list_users',                 $q$select * from public.admin_list_users()$q$, 'администратор');
  perform pg_temp.chk('get_my_context: teacher', (public.get_my_context() ->> 'role') = 'teacher' and (public.get_my_context() ->> 'is_super_admin') = 'false', public.get_my_context()::text);
  perform pg_temp.unact();

  -- DB-ниво (като собственик): връзки между училища са невъзможни
  perform pg_temp.exp_err('DB: consultation_classes клас от Б към консултация от А',
    format($q$insert into public.consultation_classes(consultation_id,class_id,school_id) select %s, k.id, k.school_id from public.classes k where k.school_id=%L limit 1$q$, v_id, B), 'foreign key');
  perform pg_temp.exp_err('DB: консултация на училище Б с учител от А',
    format($q$insert into public.consultations(teacher_id,day,shift,hour,subject,school_id) values (%L,3,2,2,'х',%L)$q$, '00000000-0000-0000-0000-00000000a002', B), 'foreign key');
  perform pg_temp.exp_err('DB: school_id е неизменим (consultations)',
    format($q$update public.consultations set school_id=%L where id=%s$q$, B, v_id), 'преместен');
  perform pg_temp.exp_err('DB: teacher не се мести в друго училище',
    $q$update public.teachers set school_id='00000000-0000-4000-8000-0000000000b0' where id='00000000-0000-0000-0000-00000000a002'$q$, 'преместен');
  perform pg_temp.exp_err('DB: членство в второ активно училище на същия потребител',
    $q$insert into public.school_memberships(user_id,school_id,role) values ('00000000-0000-0000-0000-00000000a002','00000000-0000-4000-8000-0000000000b0','teacher')$q$, 'duplicate key');
  perform pg_temp.exp_err('DB: съставен ключ – клас с (id, school_id) от различно училище',
    format($q$insert into public.consultation_classes(consultation_id,class_id,school_id) select %s, k.id, %L from public.classes k where k.school_id=%L limit 1$q$, v_id, A, B), 'foreign key');
end $$;

-- ---------- 3. Училищен администратор ----------------------------------------------------------
do $$
declare
  A constant uuid := '00000000-0000-4000-8000-000000000001';
  B constant uuid := '00000000-0000-4000-8000-0000000000b0';
  n bigint; v text; r jsonb; v_b_cons bigint; v_bdom bigint;
begin
  select count(*) into v_b_cons from public.consultations where school_id = B;
  v_bdom := (select id from public.school_email_domains where domain = 'school-b.bg');
  perform pg_temp.act('00000000-0000-0000-0000-00000000a001');
  perform pg_temp.chk('get_my_context: admin', (public.get_my_context() ->> 'role') = 'admin', public.get_my_context()::text);
  perform pg_temp.chk('админ А вижда само потребителите на А', pg_temp.cnt('select count(*) from public.admin_list_users() u join public.teachers t on t.id = u.id where t.school_id <> ''' || A || '''') = 0);
  perform pg_temp.chk('админ А не вижда други училища', pg_temp.cnt('select count(*) from public.schools') = 1);
  perform pg_temp.chk('админ А вижда домейните само на А', pg_temp.cnt('select count(*) from public.school_email_domains where school_id <> ''' || A || '''') = 0);
  perform pg_temp.exp_err('админ А: super_list_schools', $q$select * from public.super_list_schools()$q$, 'супер администратор');
  perform pg_temp.exp_err('админ А: не може set_active_school към Б', $q$select public.set_active_school('00000000-0000-4000-8000-0000000000b0')$q$, 'супер администратор');
  perform pg_temp.exp_err('админ А: не може да назначи супер админ (INSERT)', $q$insert into public.super_admins(user_id) values (auth.uid())$q$, 'permission denied');
  perform pg_temp.exp_err('админ А: super_set_school_admin', $q$select public.super_set_school_admin('00000000-0000-4000-8000-000000000001','v3teacher2.a@paisii.info',true)$q$, 'супер администратор');
  perform pg_temp.exp_err('админ А: admin_list_domains на Б',  format($q$select * from public.admin_list_domains(%L)$q$, B), 'право');
  perform pg_temp.exp_err('админ А: покана за Б', format($q$select public.admin_invite_teacher('x@x.bg', %L)$q$, B), 'право');
  perform pg_temp.exp_err('админ А: не може да назначи роля на потребител от Б', format($q$select public.admin_set_member_role(%L,'admin')$q$, '00000000-0000-0000-0000-00000000b002'), 'не е член');
  perform pg_temp.exp_err('админ А: не може да изтрие учител от Б', format($q$select public.admin_delete_teacher(%L)$q$, '00000000-0000-0000-0000-00000000b002'), 'не е намерен');
  perform pg_temp.exp_err('админ А: не променя собствената си роля', format($q$select public.admin_set_member_role(%L,'teacher')$q$, '00000000-0000-0000-0000-00000000a001'), 'собствената');
  perform pg_temp.exp_ok ('админ А: назначава А2 за admin', format($q$select public.admin_set_member_role(%L,'admin')$q$, '00000000-0000-0000-0000-00000000a003'));
  perform pg_temp.exp_err('админ А: невалидна роля super_admin', format($q$select public.admin_set_member_role(%L,'super_admin')$q$, '00000000-0000-0000-0000-00000000a002'), 'Невалидна роля');
  perform pg_temp.exp_ok ('админ А: връща А2 на teacher', format($q$select public.admin_set_member_role(%L,'teacher')$q$, '00000000-0000-0000-0000-00000000a003'));
  -- домейни
  perform pg_temp.exp_ok ('админ А: добавя свой домейн', $q$select public.admin_add_domain('Dev-A.Example.BG')$q$);
  select domain into v from public.school_email_domains where domain = 'dev-a.example.bg';
  perform pg_temp.chk('домейнът се нормализира (малки букви)', v = 'dev-a.example.bg', v);
  perform pg_temp.exp_err('админ А: невалиден домейн (интервал)', $q$select public.admin_add_domain('bad domain.bg')$q$, 'Невалиден домейн');
  perform pg_temp.exp_err('админ А: домейн без точка', $q$select public.admin_add_domain('localhost')$q$, 'Невалиден домейн');
  perform pg_temp.exp_err('админ А: публичен домейн gmail.com', $q$select public.admin_add_domain('gmail.com')$q$, 'Публични');
  perform pg_temp.exp_err('админ А: домейн на друго училище (school-b.bg)', $q$select public.admin_add_domain('school-b.bg')$q$, 'друго училище');
  perform pg_temp.exp_err('админ А: дублиран домейн', $q$select public.admin_add_domain('dev-a.example.bg')$q$, 'вече е добавен');
  perform pg_temp.exp_ok ('админ А: деактивира домейна', format($q$select public.admin_update_domain(%s,false,false)$q$, (select id from public.school_email_domains where domain='dev-a.example.bg')));
  perform pg_temp.exp_ok ('админ А: премахва домейна', format($q$select public.admin_remove_domain(%s)$q$, (select id from public.school_email_domains where domain='dev-a.example.bg')));
  perform pg_temp.exp_err('админ А: не може да пипа домейн на Б', format($q$select public.admin_remove_domain(%s)$q$, v_bdom), 'право');
  -- покани
  perform pg_temp.exp_ok ('админ А: покана за нов имейл', $q$select public.admin_invite_teacher('v3newcomer@outside.example')$q$);
  perform pg_temp.exp_err('админ А: покана за вече регистриран имейл', $q$select public.admin_invite_teacher('v3teacher2.a@paisii.info')$q$, 'регистриран');
  -- настройки и класове
  perform pg_temp.exp_ok ('админ А: настройки', $q$select public.admin_update_school_settings('Училище А ново име', '2026/2027', 'II')$q$);
  perform pg_temp.exp_err('админ А: невалидна година', $q$select public.admin_update_school_settings('Х', '2026/2028', 'I')$q$, 'Учебната година');
  perform pg_temp.exp_ok ('админ А: добавя нов клас 7Я', $q$select public.admin_add_class(7, 'Я')$q$);
  perform pg_temp.exp_err('админ А: дубликат на клас', $q$select public.admin_add_class(7, 'Я')$q$, 'вече съществува');
  perform pg_temp.exp_err('админ А: клас извън 5–12', $q$select public.admin_add_class(4, 'А')$q$, 'от 5 до 12');
  perform pg_temp.exp_ok ('админ А: предмет с групи', $q$select public.admin_set_group_subject('Тест група v3', true)$q$);
  perform pg_temp.exp_err('админ А: директен INSERT в group_subjects', $q$insert into public.group_subjects(subject) values ('х')$q$, 'permission denied');
  perform pg_temp.exp_err('админ А: директен UPDATE на teachers.role', format($q$update public.teachers set role='teacher' where id=%L$q$, '00000000-0000-0000-0000-00000000a003'), 'permission denied');
  perform pg_temp.unact();

  perform pg_temp.chk('настройките на Б не са променени', (select school_name from public.school_settings where school_id = B) = 'Тест училище Б');
  perform pg_temp.chk('schools.name на А следва настройките', (select name from public.schools where id = A) = 'Училище А ново име');
  perform pg_temp.chk('клас 7Я е само в А', pg_temp.cnt('select count(*) from public.classes where name=''7Я'' and school_id <> ''' || A || '''') = 0);
  perform pg_temp.chk('предметът с групи е само в А', pg_temp.cnt('select count(*) from public.group_subjects where subject=''Тест група v3'' and school_id <> ''' || A || '''') = 0);

  -- последен админ / изчистване / изтриване на учител – само в А
  perform pg_temp.act('00000000-0000-0000-0000-00000000a001');
  r := public.admin_delete_teacher('00000000-0000-0000-0000-00000000a003');
  perform pg_temp.unact();
  perform pg_temp.chk('админ А: изтрива учител А2 (Auth акаунт)', (select count(*) from auth.users where id = '00000000-0000-0000-0000-00000000a003') = 0, r::text);
  perform pg_temp.act('00000000-0000-0000-0000-00000000a001');
  perform pg_temp.exp_err('админ А: не изтрива себе си', format($q$select public.admin_delete_teacher(%L)$q$, '00000000-0000-0000-0000-00000000a001'), 'собствения');
  perform pg_temp.exp_ok ('админ А: admin_clear_consultations', $q$select public.admin_clear_consultations()$q$);
  perform pg_temp.unact();
  perform pg_temp.chk('изчистването на А не засяга консултациите на Б', (select count(*) from public.consultations where school_id = B) = v_b_cons, 'Б: ' || v_b_cons);
  perform pg_temp.chk('А няма консултации след изчистване', (select count(*) from public.consultations where school_id = A) = 0);
end $$;

-- последният администратор на училище не може да бъде свален
do $$
begin
  perform pg_temp.act('00000000-0000-0000-0000-000000005001');
  perform public.set_active_school('00000000-0000-4000-8000-0000000000b0');
  perform pg_temp.exp_err('последният админ на Б не може да бъде сниман на teacher', format($q$select public.admin_set_member_role(%L,'teacher')$q$, '00000000-0000-0000-0000-00000000b001'), 'последният администратор');
  perform pg_temp.exp_err('последният админ на Б не може да бъде изтрит', format($q$select public.admin_delete_teacher(%L)$q$, '00000000-0000-0000-0000-00000000b001'), 'последният администратор');
  perform pg_temp.unact();
end $$;

-- ---------- 4. Супер администратор -------------------------------------------------------------
do $$
declare
  A constant uuid := '00000000-0000-4000-8000-000000000001';
  B constant uuid := '00000000-0000-4000-8000-0000000000b0';
  v_new uuid; n bigint; v text; r record;
begin
  perform pg_temp.act('00000000-0000-0000-0000-000000005001');
  perform pg_temp.chk('get_my_context: супер админ', (public.get_my_context() ->> 'is_super_admin') = 'true' and (public.get_my_context() ->> 'role') = 'super_admin', public.get_my_context()::text);
  perform pg_temp.chk('супер админ вижда всички училища', pg_temp.cnt('select count(*) from public.super_list_schools()') >= 3);
  perform pg_temp.chk('super_list_schools връща броячи', (select teachers_count from public.super_list_schools() where id = B) = 3, (select teachers_count::text from public.super_list_schools() where id = B));
  perform pg_temp.chk('супер админ вижда schools', pg_temp.cnt('select count(*) from public.schools') >= 3);

  -- избор на училище: данните следват избраното
  perform public.set_active_school(B);
  perform pg_temp.chk('избрано Б: класовете са на Б', pg_temp.cnt('select count(*) from public.classes') = 3 and pg_temp.cnt('select count(*) from public.classes where school_id <> ''' || B || '''') = 0);
  perform pg_temp.chk('избрано Б: get_my_context.school = Б', (public.get_my_context() -> 'school' ->> 'id') = B::text);
  perform pg_temp.chk('избрано Б: админ операциите са за Б (admin_list_users)', pg_temp.cnt('select count(*) from public.admin_list_users()') = 3);
  perform public.admin_add_class(8, 'Я');
  perform public.set_active_school(A);
  perform pg_temp.chk('класът 8Я е добавен в Б, не в А', pg_temp.cnt('select count(*) from public.classes where name = ''8Я''') = 0);
  perform public.set_active_school(null);
  perform pg_temp.chk('без избрано училище (глобален изглед) данните на училищата не се виждат', pg_temp.cnt('select count(*) from public.classes') = 0 and pg_temp.cnt('select count(*) from public.consultations') = 0);
  perform pg_temp.chk('глобален изглед: is_admin() = false и get_my_context.school = null', not public.is_admin() and (public.get_my_context() -> 'school') = 'null'::jsonb, public.get_my_context()::text);
  perform pg_temp.exp_err('глобален изглед: админ операциите се отказват', $q$select public.admin_add_class(9, 'Я')$q$, 'администратор');
  perform pg_temp.exp_err('невалидно училище за избор', $q$select public.set_active_school(gen_random_uuid())$q$, 'не е намерено');

  -- създаване/промяна
  v_new := public.super_create_school('Ново училище v3', 'new-v3.example.bg');
  perform pg_temp.chk('ново училище: домейн (супер админ вижда домейните)', (select count(*) from public.school_email_domains where school_id = v_new and domain='new-v3.example.bg') = 1);
  perform pg_temp.exp_err('дублирано име на училище', $q$select public.super_create_school('  ново училище V3 ')$q$, 'Вече има училище');
  perform pg_temp.exp_err('super_create_school: невалидно име', $q$select public.super_create_school('   ')$q$, 'име');
  perform pg_temp.exp_ok ('super_update_school: деактивира', format($q$select public.super_update_school(%L, 'Ново училище v3', 'inactive')$q$, v_new));
  perform pg_temp.exp_err('super_update_school: невалиден статус', format($q$select public.super_update_school(%L, 'х', 'deleted')$q$, v_new), 'Невалиден статус');
  perform pg_temp.exp_ok ('super_update_school: активира', format($q$select public.super_update_school(%L, 'Ново училище v3 (преименувано)', 'active')$q$, v_new));
  -- администратори на училища
  perform pg_temp.exp_ok ('super_set_school_admin: Б2 -> admin', $q$select public.super_set_school_admin('00000000-0000-4000-8000-0000000000b0','v3teacher.b@school-b.bg',true)$q$);
  perform pg_temp.exp_err('super_set_school_admin: потребител от друго училище', $q$select public.super_set_school_admin('00000000-0000-4000-8000-0000000000b0','v3teacher1new.a@paisii.info',true)$q$, 'не е член');
  perform pg_temp.exp_err('super_set_school_admin: несъществуващ имейл', $q$select public.super_set_school_admin('00000000-0000-4000-8000-0000000000b0','nobody@x.bg',true)$q$, 'Няма регистриран');
  perform pg_temp.chk('super_list_school_admins вижда 2 админа на Б', pg_temp.cnt('select count(*) from public.super_list_school_admins(''' || B || ''')') = 2);
  perform pg_temp.exp_ok ('супер админ добавя домейн, зает от друго училище (с предупреждение)', format($q$select public.admin_add_domain('school-b.bg', false, %L)$q$, v_new));
  r := null;
  select conflict_count into n from public.admin_list_domains(v_new) where domain = 'school-b.bg';
  perform pg_temp.chk('admin_list_domains показва конфликт за супер админа', n = 1, n::text);
  perform pg_temp.chk('супер админ вижда имената на конфликтните училища', (select conflict_names from public.admin_list_domains(v_new) where domain='school-b.bg') is not null);
  perform pg_temp.unact();
  perform pg_temp.chk('ново училище: настройки + график (14 интервала, две смени)',
    (select count(*) from public.school_settings where school_id = v_new) = 1
    and (select count(*) from public.school_intervals where school_id = v_new) = 14
    and (select mode from public.school_schedule_settings where school_id = v_new) = 'two_shifts');
  perform pg_temp.chk('преименуването обновява и настройките', (select school_name from public.school_settings where school_id = v_new) = 'Ново училище v3 (преименувано)');
end $$;

-- ---------- 5. Неактивно училище блокира достъпа -------------------------------------------------
do $$
declare B constant uuid := '00000000-0000-4000-8000-0000000000b0';
begin
  update public.schools set status = 'inactive' where id = B;
  perform pg_temp.act('00000000-0000-0000-0000-00000000b002');
  perform pg_temp.chk('неактивно училище: учителят не вижда консултации', pg_temp.cnt('select count(*) from public.consultations') = 0);
  perform pg_temp.chk('неактивно училище: учителят не вижда класове', pg_temp.cnt('select count(*) from public.classes') = 0);
  perform pg_temp.exp_err('неактивно училище: save_consultation', $q$select public.save_consultation(null, 3, 1, 1, 'Х', 'к', array['5А'])$q$, 'активно училище');
  perform pg_temp.chk('неактивно училище: get_my_context.blocked', (public.get_my_context() ->> 'blocked') = 'true' and (public.get_my_context() ->> 'blocked_reason') = 'school_inactive', public.get_my_context()::text);
  perform pg_temp.unact();
  perform pg_temp.act('00000000-0000-0000-0000-00000000b001');
  perform pg_temp.exp_err('неактивно училище: и админът е блокиран', $q$select public.admin_add_class(9, 'А')$q$, 'администратор');
  perform pg_temp.unact();
  -- супер админ може да работи в неактивно училище (за да го реактивира)
  perform pg_temp.act('00000000-0000-0000-0000-000000005001');
  perform public.set_active_school(B);
  perform pg_temp.chk('супер админ работи в неактивно училище', pg_temp.cnt('select count(*) from public.classes') > 0);
  perform public.set_active_school(null);
  perform pg_temp.unact();
  update public.schools set status = 'active' where id = B;
  perform pg_temp.act('00000000-0000-0000-0000-00000000b002');
  perform pg_temp.chk('след реактивиране достъпът се връща', pg_temp.cnt('select count(*) from public.classes') > 0);
  perform pg_temp.unact();
end $$;

-- ---------- 6. Конфигурируем график ------------------------------------------------------------------
do $$
declare
  A constant uuid := '00000000-0000-4000-8000-000000000001';
  B constant uuid := '00000000-0000-4000-8000-0000000000b0';
  v_id bigint; r jsonb; n bigint; v text;
begin
  -- по подразбиране = днешното поведение
  perform pg_temp.chk('по подразбиране: 14 интервала (7+7), режим две смени', (select count(*) from public.school_intervals where school_id = A) = 14 and (select mode from public.school_schedule_settings where school_id = A) = 'two_shifts');
  perform pg_temp.chk('смяна 1, час 1 = 12:35–13:15', (select to_char(start_time,'HH24:MI') || '-' || to_char(end_time,'HH24:MI') from public.school_intervals where school_id=A and shift=1 and position=1) = '12:35-13:15');
  perform pg_temp.chk('смяна 1, час 7 = 17:50–18:30', (select to_char(start_time,'HH24:MI') || '-' || to_char(end_time,'HH24:MI') from public.school_intervals where school_id=A and shift=1 and position=7) = '17:50-18:30');
  perform pg_temp.chk('смяна 2, час 1 = 07:30–08:10', (select to_char(start_time,'HH24:MI') || '-' || to_char(end_time,'HH24:MI') from public.school_intervals where school_id=A and shift=2 and position=1) = '07:30-08:10');
  perform pg_temp.chk('смяна 2, час 7 = 12:35–13:15 (независима клетка от I/7 – различни ключове)', (select to_char(start_time,'HH24:MI') from public.school_intervals where school_id=A and shift=2 and position=7) = '12:35');

  perform pg_temp.act('00000000-0000-0000-0000-00000000a002');
  -- I/7 и II/1 са независими клетки; един и същ учител/предмет/клас е позволен
  perform pg_temp.exp_ok('I/7 (запис)',  $q$select public.save_consultation(null, 1, 1, 7, 'Математика', 'каб. 1', array['5А','5Б'])$q$);
  perform pg_temp.exp_ok('II/1 със същото съдържание е позволено (независими клетки)', $q$select public.save_consultation(null, 1, 2, 1, 'Математика', 'каб. 1', array['5А','5Б'])$q$);
  perform pg_temp.exp_err('същият слот (ден+смяна+час) за същия учител = конфликт', $q$select public.save_consultation(null, 1, 1, 7, 'Физика', 'к', array['5А'])$q$, 'вече има друга консултация');
  perform pg_temp.exp_err('смяна 3 е невалидна', $q$select public.save_consultation(null, 2, 3, 1, 'Х', 'к', array['5А'])$q$, 'Невалиден ден, смяна или час');
  perform pg_temp.exp_err('час 8 е невалиден при две смени', $q$select public.save_consultation(null, 2, 1, 8, 'Х', 'к', array['5А'])$q$, 'Невалиден ден, смяна или час');
  perform pg_temp.unact();

  -- режим „една смяна“: блокира се, докато има консултации в смяна II
  perform pg_temp.act('00000000-0000-0000-0000-00000000a001');
  r := public.admin_schedule_change_impact('one_shift');
  perform pg_temp.chk('impact: blocked при консултации в смяна II', (r ->> 'blocked') = 'true', r::text);
  perform pg_temp.exp_err('режим one_shift се отказва при консултации в смяна II', $q$select public.admin_set_schedule_mode('one_shift', true)$q$, 'смяна II');
  perform pg_temp.chk('режимът не е променен след отказ', (public.get_school_schedule() ->> 'mode') = 'two_shifts');
  delete from public.consultations where school_id = A and shift = 2;          -- ръчно изтриване от админа (RLS: admin)
  perform pg_temp.exp_err('без потвърждение при наличие на консултации -> отказ', $q$select public.admin_set_schedule_mode('one_shift', false)$q$, 'потвърдете');
  perform pg_temp.exp_ok ('с потвърждение -> one_shift', $q$select public.admin_set_schedule_mode('one_shift', true)$q$);
  r := public.get_school_schedule(true);
  perform pg_temp.chk('one_shift: режимът е записан', (r ->> 'mode') = 'one_shift', r::text);
  perform pg_temp.chk('one_shift: само смяна 1, интервалите са запазени', jsonb_array_length(r -> 'intervals') = 7 and (r -> 'intervals' -> 0 ->> 'shift') = '1');
  perform pg_temp.chk('one_shift: използваните позиции са отчетени', (r -> 'intervals' -> 6 ->> 'used') = '1', (r -> 'intervals' -> 6)::text);
  perform pg_temp.unact();

  perform pg_temp.act('00000000-0000-0000-0000-00000000a002');
  perform pg_temp.exp_err('one_shift: смяна 2 е невалидна на сървъра', $q$select public.save_consultation(null, 2, 2, 1, 'Х', 'к', array['5А'])$q$, 'Невалиден ден, смяна или час');
  perform pg_temp.exp_err('one_shift: позиция 8 още не съществува', $q$select public.save_consultation(null, 2, 1, 8, 'Х', 'к', array['5А'])$q$, 'Невалиден ден, смяна или час');
  perform pg_temp.unact();

  perform pg_temp.act('00000000-0000-0000-0000-00000000a001');
  perform pg_temp.exp_ok ('one_shift: добавя интервал 8', $q$select public.admin_save_interval(1, 8, '18:40', '19:20')$q$);
  perform pg_temp.exp_err('one_shift: нов интервал само в края (позиция 10)', $q$select public.admin_save_interval(1, 10, '19:30', '20:00')$q$, 'в края');
  perform pg_temp.exp_err('one_shift: припокриване', $q$select public.admin_save_interval(1, 9, '19:00', '19:40')$q$, 'припокрива');
  perform pg_temp.exp_err('one_shift: начало >= край', $q$select public.admin_save_interval(1, 9, '19:40', '19:40')$q$, 'Началото');
  perform pg_temp.exp_err('one_shift: смяна 2 не е позволена', $q$select public.admin_save_interval(2, 1, '07:30', '08:10')$q$, 'една смяна');
  perform pg_temp.exp_err('редакция на използван интервал без потвърждение', $q$select public.admin_save_interval(1, 7, '17:55', '18:35')$q$, 'потвърдете');
  perform pg_temp.exp_ok ('редакция на използван интервал с потвърждение', $q$select public.admin_save_interval(1, 7, '17:55', '18:35', true)$q$);
  perform pg_temp.exp_ok ('редакция на неизползван интервал без потвърждение', $q$select public.admin_save_interval(1, 3, '14:20', '14:55')$q$);
  perform pg_temp.exp_err('редакция, което припокрива следващия (интервал 3 до 10:20)', $q$select public.admin_save_interval(1, 3, '14:20', '15:20')$q$, 'припокрива');
  perform pg_temp.exp_err('не може да се изтрие средна позиция (без преномериране)', $q$select public.admin_delete_interval(1, 3)$q$, 'последният');
  perform pg_temp.exp_err('не може да се изтрие използвана позиция', $q$select public.admin_delete_interval(1, 7)$q$, 'последният');
  perform pg_temp.exp_ok ('изтрива последния неизползван (8)', $q$select public.admin_delete_interval(1, 8)$q$);
  perform pg_temp.unact();
  perform pg_temp.chk('DB: FK не позволява изтриване на използвана позиция (собственик)',
    (select count(*) from public.consultations where school_id = A and shift = 1 and hour = 7) = 1);
  perform pg_temp.exp_err('DB: директно DELETE на използван интервал', format($q$delete from public.school_intervals where school_id=%L and shift=1 and position=7$q$, A), 'foreign key');
  perform pg_temp.chk('графикът на Б не е засегнат', (select mode from public.school_schedule_settings where school_id = B) = 'two_shifts' and (select count(*) from public.school_intervals where school_id = B) = 14);

  -- обратно към две смени
  perform pg_temp.act('00000000-0000-0000-0000-00000000a001');
  perform pg_temp.exp_ok ('обратно към две смени', $q$select public.admin_set_schedule_mode('two_shifts', true)$q$);
  perform pg_temp.chk('две смени: 7+7 позиции', (select count(*) from public.school_intervals where school_id = A) = 14);
  perform pg_temp.exp_err('две смени: добавяне на позиция не е позволено', $q$select public.admin_save_interval(1, 8, '19:00', '19:40')$q$, 'фиксирани');
  perform pg_temp.unact();
  perform pg_temp.act('00000000-0000-0000-0000-00000000a002');
  perform pg_temp.exp_ok ('две смени: смяна 2 отново е валидна', $q$select public.save_consultation(null, 3, 2, 2, 'Х', 'к', array['5А'])$q$);
  perform pg_temp.unact();
end $$;

-- ---------- Резултат --------------------------------------------------------------------------------
select test, ok, detail from res where not ok order by 1;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from res;
rollback;
