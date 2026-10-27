-- =====================================================================
-- v3.1: проверки на регистрацията/ролите/bootstrap (миграции 20261012 – 20261016)
-- Изпълнява се СЛЕД всички миграции, като собственик, в ТРАНЗАКЦИЯ С ROLLBACK, само на ТЕСТОВА/локална база.
-- Покрива 11-те задължителни сценария + допълнителни атаки. Резултат: (test, ok, detail).
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

-- ---------- Данни: две училища (A: a-school.test, B: b-school.test), неактивно C, двусмислен домейн ---------
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid(); d uuid := gen_random_uuid();
begin
  delete from public.super_admins;                       -- симулира „няма супер админ“ (в rollback транзакция)
  insert into public.schools(id, name, status) values (a,'Училище A','active'),(b,'Училище B','active'),
         (c,'Училище C (неактивно)','inactive'),(d,'Училище D','active');
  insert into public.school_email_domains(school_id, domain, active) values
    (a,'a-school.test',true),(b,'b-school.test',true),(c,'c-school.test',true);
  perform set_config('t.a', a::text, true); perform set_config('t.b', b::text, true);
  perform set_config('t.c', c::text, true); perform set_config('t.d', d::text, true);
end $$;

-- ====== 1. teacher@A-домейн -> School A, teacher =====
insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000a1','teacher@a-school.test','{"name":"Учител А","role":"admin","school_id":"x"}');
select pg_temp.chk('1 teacher@A -> членство в A с роля teacher',
  (select count(*) from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000a1' and school_id=current_setting('t.a')::uuid and role='teacher' and status='active')=1);
select pg_temp.chk('1b клиентски role/school_id в metadata се игнорират (teachers.role=teacher, school=A)',
  (select count(*) from public.teachers where id='00000000-0000-0000-0000-0000000000a1' and role='teacher' and school_id=current_setting('t.a')::uuid)=1);
select pg_temp.chk('1c не е супер админ', not exists (select 1 from public.super_admins where user_id='00000000-0000-0000-0000-0000000000a1'));

-- ====== 2. teacher@B-домейн -> School B =====
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000b1','teacher@b-school.test');
select pg_temp.chk('2 teacher@B -> членство в B',
  (select count(*) from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000b1' and school_id=current_setting('t.b')::uuid)=1);
select pg_temp.chk('2b няма членство в A',
  not exists (select 1 from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000b1' and school_id=current_setting('t.a')::uuid));

-- ====== 3. неизвестен домейн =====
select pg_temp.exp_err('3 неизвестен домейн -> CS001',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'x@unknown.test')$$, 'Регистрацията е разрешена само');
-- ====== 4. неактивно училище =====
select pg_temp.exp_err('4 домейн на неактивно училище -> отказ',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'x@c-school.test')$$, 'не е активно');
-- ====== 5. двусмислен домейн =====
-- (уникалният индекс не позволява два активни реда за един домейн -> двусмислие само чрез allow_subdomains)
do $$ begin
  insert into public.school_email_domains(school_id, domain, active, allow_subdomains) values (current_setting('t.d')::uuid, 'shared.test', true, false);
  begin
    insert into public.school_email_domains(school_id, domain, active, allow_subdomains) values (current_setting('t.a')::uuid, 'sub.shared.test', true, false);
  exception when others then null; end;
  update public.school_email_domains set allow_subdomains = true where domain = 'shared.test';
  insert into public.school_email_domains(school_id, domain, active) values (current_setting('t.b')::uuid, 'sub.shared.test', true);
end $$;
select pg_temp.exp_err('5 домейн, съвпадащ с повече от едно училище -> ambiguous',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'x@sub.shared.test')$$, 'повече от едно училище');

-- ====== 6. валидна покана (имейл извън всички училищни домейни) =====
do $$ begin
  insert into public.school_invites(school_id, email) values (current_setting('t.a')::uuid, 'invited@other.test');
end $$;
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000a6','invited@other.test');
select pg_temp.chk('6 покана -> членство в A, поканата е used',
  (select count(*) from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000a6' and school_id=current_setting('t.a')::uuid and role='teacher')=1
  and (select status from public.school_invites where email='invited@other.test')='used');

-- ====== 7./8. @edu.mon.bg: обикновен потребител е отказан; упълномощен админ минава =====
select pg_temp.exp_err('8 обикновен @edu.mon.bg без покана -> CS001',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'someone@edu.mon.bg')$$, 'Регистрацията е разрешена само');
select pg_temp.chk('8b edu.mon.bg не е училищен домейн',
  not exists (select 1 from public.school_email_domains where domain='edu.mon.bg'));

-- bootstrap: функцията не е достъпна за anon/authenticated
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select pg_temp.exp_err('9a bootstrap_first_super_admin недостъпна за authenticated',
  $$select public.bootstrap_first_super_admin('teacher@a-school.test')$$, 'permission denied');
select pg_temp.exp_err('9b super_add_super_admin от обикновен учител -> отказ',
  $$select public.super_add_super_admin('evil@edu.mon.bg')$$, 'Само супер администратор');
select pg_temp.exp_err('9c директен insert в super_admins от учител -> отказ',
  $$insert into public.super_admins(user_id) values ('00000000-0000-0000-0000-0000000000a1')$$, 'permission denied');
select pg_temp.exp_err('9d директен insert в super_admin_invites -> отказ',
  $$insert into public.super_admin_invites(email) values ('evil@edu.mon.bg')$$, 'permission denied');
select pg_temp.unact();

select pg_temp.exp_err('7a bootstrap с невалиден имейл', $$select public.bootstrap_first_super_admin('replace_with_email')$$, 'Невалиден');
create temp table boot_res as select public.bootstrap_first_super_admin('admin@edu.mon.bg') as msg;
select pg_temp.chk('7b bootstrap за несъществуващ Auth потребител -> INVITED, без измислен UUID',
  (select msg from boot_res) like 'INVITED:%'
  and (select count(*) from public.super_admins)=0
  and (select count(*) from public.super_admin_invites where email='admin@edu.mon.bg' and status='pending')=1);
select pg_temp.exp_err('7c все още друг @edu.mon.bg е отказан (домейнът не дава права)',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'other@edu.mon.bg')$$, 'Регистрацията е разрешена само');
insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000f1','admin@edu.mon.bg','{"name":"Първи"}');
select pg_temp.chk('7d admin@edu.mon.bg е създаден и е супер админ (реален id от auth.users)',
  exists (select 1 from public.super_admins where user_id='00000000-0000-0000-0000-0000000000f1')
  and (select status from public.super_admin_invites where email='admin@edu.mon.bg')='used');
select pg_temp.chk('7e супер админът няма принудително училище/учителски профил',
  not exists (select 1 from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000f1')
  and not exists (select 1 from public.teachers where id='00000000-0000-0000-0000-0000000000f1'));
select pg_temp.exp_err('7f bootstrap втори път -> отказ (вече има супер админ)',
  $$select public.bootstrap_first_super_admin('another@edu.mon.bg')$$, 'Вече има супер администратор');
select pg_temp.exp_err('7g другият @edu.mon.bg пак е отказан след първия',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'other@edu.mon.bg')$$, 'Регистрацията е разрешена само');

-- ====== 9. супер админ: вход (контекст) без училище, управление, добавяне на друг супер админ =====
select pg_temp.act('00000000-0000-0000-0000-0000000000f1');
select pg_temp.chk('9 get_my_context: супер админ, не е blocked, без училище',
  (public.get_my_context()->>'is_super_admin')::boolean and not (public.get_my_context()->>'blocked')::boolean
  and public.get_my_context()->'school' = 'null'::jsonb);
select pg_temp.exp_ok('9e super_add_super_admin за несъществуващ имейл -> покана',
  $$select public.super_add_super_admin('second@edu.mon.bg')$$);
select pg_temp.chk('9f списъкът показва 1 админ и 1 покана',
  (select count(*) from public.super_list_super_admins() where kind='admin')=1
  and (select count(*) from public.super_list_super_admins() where kind='invite')=1);
select pg_temp.exp_err('9g не може да се премахне последният супер админ',
  $$select public.super_remove_super_admin('00000000-0000-0000-0000-0000000000f1')$$, 'последният');
select pg_temp.unact();
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000f2','second@edu.mon.bg');
select pg_temp.chk('9h вторият супер админ се създава от поканата', exists (select 1 from public.super_admins where user_id='00000000-0000-0000-0000-0000000000f2'));
select pg_temp.act('00000000-0000-0000-0000-0000000000f1');
select pg_temp.exp_ok('9i вече могат да се премахват (има 2)', $$select public.super_remove_super_admin('00000000-0000-0000-0000-0000000000f2')$$);
select pg_temp.exp_ok('9j добавяне на ВЕЧЕ съществуващ Auth потребител -> directly granted', $$select public.super_add_super_admin('teacher@b-school.test')$$);
select pg_temp.unact();
select pg_temp.chk('9k teacher@B е супер админ след grant', exists (select 1 from public.super_admins where user_id='00000000-0000-0000-0000-0000000000b1'));
select pg_temp.act('00000000-0000-0000-0000-0000000000f1');
select pg_temp.exp_err('9l невалиден имейл', $$select public.super_add_super_admin('not-an-email')$$, 'Невалиден');
-- покана за администратор на училище извън училищен домейн: покана (school_invites) + повишаване
select pg_temp.exp_ok('9m супер админ поканва admin@edu.mon.bg-подобен имейл в училище A (покана заобикаля домейна)',
  $$select public.admin_invite_teacher('schooladmin@edu.mon.bg', current_setting('t.a')::uuid)$$);
select pg_temp.unact();
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000a9','schooladmin@edu.mon.bg');
select pg_temp.chk('9n schooladmin@edu.mon.bg е член (teacher) на A чрез покана',
  (select role from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000a9' and school_id=current_setting('t.a')::uuid)='teacher');
select pg_temp.act('00000000-0000-0000-0000-0000000000f1');
select pg_temp.exp_ok('9o супер админ го прави администратор на A',
  $$select public.super_set_school_admin(current_setting('t.a')::uuid, 'schooladmin@edu.mon.bg', true)$$);
select pg_temp.unact();
select pg_temp.chk('9p ролите са без конфликт: membership=admin, teachers.role=admin, не е супер админ',
  (select role from public.school_memberships where user_id='00000000-0000-0000-0000-0000000000a9')='admin'
  and (select role from public.teachers where id='00000000-0000-0000-0000-0000000000a9')='admin'
  and not exists (select 1 from public.super_admins where user_id='00000000-0000-0000-0000-0000000000a9'));

-- ====== 10. teacher от A не вижда/променя данни на B =====
do $$
declare ta uuid := '00000000-0000-0000-0000-0000000000a1'; tb uuid := '00000000-0000-0000-0000-0000000000b1';
begin
  insert into public.classes(name, school_id) values ('10А-тест', current_setting('t.a')::uuid), ('10Б-тест', current_setting('t.b')::uuid);
end $$;
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select pg_temp.chk('10 teacher A вижда само класове на A',
  (select count(*) from public.classes where school_id=current_setting('t.b')::uuid)=0
  and (select count(*) from public.classes where school_id=current_setting('t.a')::uuid)>=1);
select pg_temp.chk('10b teacher A не вижда учителя от B', (select count(*) from public.teachers where id='00000000-0000-0000-0000-0000000000b1')=0);
select pg_temp.exp_err('10c teacher A не може да избере училище B', $$select public.set_active_school(current_setting('t.b')::uuid)$$, 'супер администратор');
select pg_temp.chk('10d teacher A не може да трие клас на B (0 реда)',
  pg_temp.cnt($$with d as (delete from public.classes where school_id=current_setting('t.b')::uuid returning 1) select count(*) from d$$)=0);
select pg_temp.unact();

-- ====== 11. супер админ достъпва A и B (изрично избиране) =====
select pg_temp.act('00000000-0000-0000-0000-0000000000f1');
select pg_temp.chk('11a без избрано училище (глобален изглед) не вижда класове на A/B през RLS',
  (select count(*) from public.classes where school_id in (current_setting('t.a')::uuid, current_setting('t.b')::uuid))=0);
select pg_temp.exp_ok('11b избира A', $$select public.set_active_school(current_setting('t.a')::uuid)$$);
select pg_temp.chk('11c вижда класове на A, не на B',
  (select count(*) from public.classes where school_id=current_setting('t.a')::uuid)>=1
  and (select count(*) from public.classes where school_id=current_setting('t.b')::uuid)=0);
select pg_temp.exp_ok('11d избира B', $$select public.set_active_school(current_setting('t.b')::uuid)$$);
select pg_temp.chk('11e вижда класове на B, не на A',
  (select count(*) from public.classes where school_id=current_setting('t.b')::uuid)>=1
  and (select count(*) from public.classes where school_id=current_setting('t.a')::uuid)=0);
select pg_temp.unact();

-- ====== Допълнително: поканата за супер админ изтича и не е домейн-базирана =====
update public.super_admin_invites set status='cancelled' where status='pending';
insert into public.super_admin_invites(email, expires_at, created_at) values ('late@edu.mon.bg', now() - interval '1 hour', now() - interval '2 hours');
select pg_temp.exp_err('12 изтекла покана за супер админ не отваря регистрация',
  $$insert into auth.users(id,email) values (gen_random_uuid(),'late@edu.mon.bg')$$, 'Регистрацията е разрешена само');
select pg_temp.chk('12b покана за един имейл не отваря друг имейл от същия домейн',
  (select count(*) from public.super_admin_invites where status='pending' and expires_at > now())=0);
-- смяна на имейл от учител към друг домейн остава блокирана
select pg_temp.exp_err('13 учител не може да смени имейла към @edu.mon.bg',
  $$update auth.users set email='teacher@edu.mon.bg' where id='00000000-0000-0000-0000-0000000000a1'$$, 'Новият имейл');
-- hook
select pg_temp.chk('14 hook: неизвестен домейн -> грешка; поканен супер админ -> {}',
  (public.hook_before_user_created('{"user":{"email":"zzz@unknown.test"}}'::jsonb)) ? 'error'
  and (public.hook_before_user_created('{"user":{"email":"teacher@a-school.test"}}'::jsonb)) = '{}'::jsonb);
-- RLS включен
select pg_temp.chk('15 RLS е включен върху всички ключови таблици',
  (select bool_and(relrowsecurity) from pg_class where oid in ('public.schools'::regclass,'public.school_email_domains'::regclass,
   'public.school_memberships'::regclass,'public.super_admins'::regclass,'public.school_invites'::regclass,
   'public.super_admin_invites'::regclass,'public.teachers'::regclass,'public.classes'::regclass,'public.consultations'::regclass)));

select test, ok, detail from res order by 1;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from res;
rollback;
