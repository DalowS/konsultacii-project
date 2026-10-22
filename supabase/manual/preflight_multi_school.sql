-- =====================================================================
-- PREFLIGHT / ПРОВЕРКА ЗА ГОТОВНОСТ – многоучилищна версия (v3.0)
-- Само за ЧЕТЕНЕ: не променя нищо в public/auth (създава само временна таблица за резултата в сесията).
-- Изпълнява се в Supabase -> SQL Editor (като собственик/postgres).
--
-- КОГА:  (1) ПРЕДИ миграциите – показва какво ще срещнат (раздел „ПРЕДИ“, статус INFO/WARN);
--        (2) СЛЕД 20261012–20261015 – пълната проверка (раздел „СЛЕД“). Ако таблицата public.schools
--            още не съществува, „СЛЕД“ проверките се пропускат и това е отбелязано.
-- РЕЗУЛТАТ: колони раздел | проверка | статус | детайл.   статус: OK | ERROR | WARN | INFO
--   ERROR = не пускайте/поправете преди работа; WARN = преглед, може да е нормално; INFO = информация.
-- Резултатът от локален PostgreSQL НЕ е доказателство за реалния Supabase – пускайте го там.
-- =====================================================================
create temp table if not exists pf_result (n serial, section text, check_name text, status text, detail text) on commit preserve rows;
truncate pf_result;

create or replace function pg_temp.pf(p_section text, p_check text, p_status text, p_detail text default '')
returns void language sql as $$
  insert into pf_result (section, check_name, status, detail) values (p_section, p_check, p_status, p_detail)
$$;
-- ok = true -> OK, иначе p_bad (ERROR или WARN)
create or replace function pg_temp.pf_chk(p_section text, p_check text, p_ok boolean, p_bad text default 'ERROR', p_detail text default '')
returns void language sql as $$
  insert into pf_result (section, check_name, status, detail)
  values (p_section, p_check, case when coalesce(p_ok, false) then 'OK' else p_bad end, p_detail)
$$;
create or replace function pg_temp.pf_count(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute p_sql into n; return n; end $$;

do $pf$
declare
  S1 constant text := '1 ПРЕДИ (v2.9 данни)';
  S2 constant text := '2 СЛЕД (структура)';
  S3 constant text := '3 СЛЕД (данни)';
  S4 constant text := '4 СЛЕД (сигурност)';
  t text; n bigint; v_has_ms boolean; r record;
  v_initial constant uuid := '00000000-0000-4000-8000-000000000001';
begin
  v_has_ms := to_regclass('public.schools') is not null;

  -- ===================== 1. ПРЕДИ / общо =====================
  foreach t in array array['teachers','classes','consultations','consultation_classes','group_subjects','school_settings'] loop
    perform pg_temp.pf_chk(S1, 'таблица public.' || t || ' съществува', to_regclass('public.' || t) is not null, 'ERROR');
  end loop;
  perform pg_temp.pf(S1, 'брой teachers / classes / consultations / consultation_classes / group_subjects', 'INFO',
    concat_ws(' / ', pg_temp.pf_count('select count(*) from public.teachers'), pg_temp.pf_count('select count(*) from public.classes'),
      pg_temp.pf_count('select count(*) from public.consultations'), pg_temp.pf_count('select count(*) from public.consultation_classes'),
      pg_temp.pf_count('select count(*) from public.group_subjects')));
  perform pg_temp.pf(S1, 'брой auth.users', 'INFO', pg_temp.pf_count('select count(*) from auth.users')::text);
  n := pg_temp.pf_count('select count(*) from public.teachers where role = ''admin''');
  perform pg_temp.pf_chk(S1, 'има поне един администратор (teachers.role = admin)', n >= 1, 'WARN', 'admins: ' || n);
  n := pg_temp.pf_count('select count(*) from auth.users u where not exists (select 1 from public.teachers t where t.id = u.id)');
  perform pg_temp.pf_chk(S1, 'auth потребители без профил в teachers (не могат да влязат – както и във v2.9)', n = 0, 'WARN', 'брой: ' || n);
  n := pg_temp.pf_count('select count(*) from public.teachers t where not exists (select 1 from auth.users u where u.id = t.id)');
  perform pg_temp.pf_chk(S1, 'профили в teachers без auth потребител', n = 0, 'WARN', 'брой: ' || n);
  n := pg_temp.pf_count('select count(*) from public.consultations where hour not between 1 and 7 or shift not in (1, 2)');
  perform pg_temp.pf_chk(S1, 'консултации със стар/невалиден час или смяна (НЕ се променят и НЕ се трият от миграциите)', n = 0, 'WARN',
    'брой: ' || n || case when n > 0 then ' – показват се като „невалиден час“; изтрийте/създайте ги отново от интерфейса' else '' end);
  n := pg_temp.pf_count('select count(*) from (select teacher_id, day, shift, hour from public.consultations group by 1,2,3,4 having count(*) > 1) x');
  perform pg_temp.pf_chk(S1, 'дублирани слотове на учител (ден+смяна+час)', n = 0, 'ERROR', 'брой: ' || n);
  n := pg_temp.pf_count('select count(*) from (select lower(btrim(school_name)) from public.school_settings group by 1) x');
  perform pg_temp.pf(S1, 'име на училището в school_settings (става име на първоначалното училище)', 'INFO',
    coalesce((select school_name from public.school_settings order by id limit 1), '<няма ред>'));

  if not v_has_ms then
    perform pg_temp.pf(S1, 'миграции 20261012–20261015', 'INFO', 'още НЕ са приложени (public.schools липсва) – „СЛЕД“ проверките са пропуснати');
    -- глобални уникални индекси, които ще бъдат премахнати от 20261012/20261015
    for r in
      select i.indrelid::regclass::text tbl, ic.relname idx, pg_get_indexdef(i.indexrelid) def
        from pg_index i join pg_class ic on ic.oid = i.indexrelid
       where i.indrelid in ('public.classes'::regclass, 'public.group_subjects'::regclass)
         and i.indisunique and not i.indisprimary
    loop
      perform pg_temp.pf(S1, 'глобален unique индекс върху ' || r.tbl || ' (ще бъде премахнат от 20261012/20261015)', 'INFO', r.def);
    end loop;
    return;
  end if;

  -- ===================== 2. СЛЕД: структура =====================
  foreach t in array array['schools','school_email_domains','school_memberships','super_admins','super_admin_context','school_invites',
                           'school_schedule_settings','school_intervals','multi_school_audit'] loop
    perform pg_temp.pf_chk(S2, 'таблица public.' || t, to_regclass('public.' || t) is not null, 'ERROR');
  end loop;
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings'] loop
    perform pg_temp.pf_chk(S2, 'колона school_id NOT NULL в ' || t,
      exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'school_id' and is_nullable = 'NO'), 'ERROR');
  end loop;
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings','schools',
                           'school_email_domains','school_memberships','super_admins','super_admin_context','school_invites',
                           'school_schedule_settings','school_intervals','multi_school_audit','consultation_stage_shifts'] loop
    if to_regclass('public.' || t) is not null then
      perform pg_temp.pf_chk(S2, 'RLS е включен: ' || t, (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass), 'ERROR');
    end if;
  end loop;
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings','schools',
                           'school_email_domains','school_memberships','super_admins','school_invites','school_schedule_settings','school_intervals'] loop
    perform pg_temp.pf_chk(S2, 'има SELECT политика: ' || t,
      exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and cmd in ('SELECT', 'ALL')), 'ERROR');
  end loop;
  -- RPC функции
  foreach t in array array['get_my_context','set_active_school','current_school_id','is_admin','is_super_admin','is_school_admin','save_consultation',
      'import_consultations','get_school_schedule','super_list_schools','super_create_school','super_update_school','super_set_school_admin',
      'super_list_school_admins','admin_list_domains','admin_add_domain','admin_update_domain','admin_remove_domain','admin_invite_teacher',
      'admin_cancel_invite','admin_list_users','admin_set_member_role','admin_delete_teacher','admin_update_school_settings','admin_add_class',
      'admin_set_group_subject','admin_clear_consultations','admin_schedule_change_impact','admin_set_schedule_mode','admin_save_interval',
      'admin_delete_interval','resolve_registration_school','enforce_email_domain','handle_new_user'] loop
    perform pg_temp.pf_chk(S2, 'функция ' || t, exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                                                          where ns.nspname = 'public' and p.proname = t), 'ERROR');
  end loop;
  -- тригери върху auth.users
  perform pg_temp.pf_chk(S2, 'trigger auth_users_email_domain (BEFORE INSERT/UPDATE OF email) върху auth.users',
    exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'auth_users_email_domain' and not tgisinternal), 'ERROR');
  perform pg_temp.pf_chk(S2, 'trigger on_auth_user_created (AFTER INSERT) върху auth.users',
    exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created' and not tgisinternal), 'ERROR');
  -- Realtime
  foreach t in array array['consultations','consultation_classes','group_subjects','classes','teachers','school_settings','school_schedule_settings','school_intervals','schools'] loop
    perform pg_temp.pf_chk(S2, 'Realtime публикация съдържа ' || t,
      exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t), 'WARN',
      'без това промените не се виждат на живо (приложете 20261015)');
  end loop;
  -- глобални уникални индекси, останали след миграцията
  n := (select count(*) from pg_index i where i.indrelid in ('public.classes'::regclass, 'public.group_subjects'::regclass)
          and i.indisunique and not i.indisprimary and pg_get_indexdef(i.indexrelid) !~ 'school_id');
  perform pg_temp.pf_chk(S2, 'няма глобална уникалност върху classes/group_subjects без school_id', n = 0, 'ERROR',
    'брой: ' || n || ' (второ училище не би могло да има същия клас/предмет; приложете 20261015)');
  perform pg_temp.pf_chk(S2, 'unique (school_id, name) върху classes', to_regclass('public.classes_school_name_uq') is not null, 'ERROR');
  perform pg_temp.pf_chk(S2, 'unique (school_id, subject) върху group_subjects', to_regclass('public.group_subjects_school_subject_uq') is not null, 'ERROR');
  perform pg_temp.pf_chk(S2, 'съставен FK консултация -> учител (id, school_id)', exists (select 1 from pg_constraint where conname = 'consultations_teacher_school_fk'), 'ERROR');
  perform pg_temp.pf_chk(S2, 'съставен FK връзка -> консултация (id, school_id)', exists (select 1 from pg_constraint where conname = 'consultation_classes_consultation_school_fk'), 'ERROR');
  perform pg_temp.pf_chk(S2, 'съставен FK връзка -> клас (id, school_id)', exists (select 1 from pg_constraint where conname = 'consultation_classes_class_school_fk'), 'ERROR');
  perform pg_temp.pf_chk(S2, 'FK консултация -> интервал (school_id, shift, hour) [NOT VALID – старите редове не се проверяват]', exists (select 1 from pg_constraint where conname = 'consultations_interval_fk'), 'ERROR');

  -- ===================== 3. СЛЕД: данни =====================
  perform pg_temp.pf_chk(S3, 'първоначалното училище съществува (id ...0001)', exists (select 1 from public.schools where id = v_initial), 'ERROR');
  perform pg_temp.pf(S3, 'училища', 'INFO', coalesce((select string_agg(name || ' [' || status || ']', '; ' order by created_at) from public.schools), ''));
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings'] loop
    n := pg_temp.pf_count(format('select count(*) from public.%I where school_id is null', t));
    perform pg_temp.pf_chk(S3, 'редове без school_id: ' || t, n = 0, 'ERROR', 'брой: ' || n);
    n := pg_temp.pf_count(format('select count(*) from public.%I x where not exists (select 1 from public.schools s where s.id = x.school_id)', t));
    perform pg_temp.pf_chk(S3, 'осиротели school_id (няма такова училище): ' || t, n = 0, 'ERROR', 'брой: ' || n);
  end loop;
  n := (select count(*) from public.consultation_classes cc join public.consultations c on c.id = cc.consultation_id
         join public.classes k on k.id = cc.class_id where cc.school_id <> c.school_id or cc.school_id <> k.school_id);
  perform pg_temp.pf_chk(S3, 'consultation_classes: клас и консултация от РАЗЛИЧНИ училища', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.consultations c join public.teachers t on t.id = c.teacher_id where t.school_id <> c.school_id);
  perform pg_temp.pf_chk(S3, 'консултации с учител от друго училище', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.teachers t where not exists (select 1 from public.school_memberships m where m.user_id = t.id and m.status = 'active'));
  perform pg_temp.pf_chk(S3, 'профили без активно членство', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.school_memberships m join public.teachers t on t.id = m.user_id where t.school_id <> m.school_id and m.status = 'active');
  perform pg_temp.pf_chk(S3, 'членство в училище, различно от school_id на профила', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from (select user_id from public.school_memberships where status = 'active' group by 1 having count(*) > 1) x);
  perform pg_temp.pf_chk(S3, 'потребители с повече от едно активно членство', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.school_memberships m join public.teachers t on t.id = m.user_id where m.status = 'active' and m.role is distinct from t.role);
  perform pg_temp.pf_chk(S3, 'teachers.role се различава от membership.role', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.school_memberships m where not exists (select 1 from public.teachers t where t.id = m.user_id));
  perform pg_temp.pf_chk(S3, 'членства без профил в teachers', n = 0, 'WARN', 'брой: ' || n);
  n := (select count(*) from public.schools s where s.status = 'active'
          and not exists (select 1 from public.school_memberships m where m.school_id = s.id and m.role = 'admin' and m.status = 'active'));
  perform pg_temp.pf_chk(S3, 'активни училища без администратор', n = 0, 'WARN', 'брой: ' || n);
  n := (select count(*) from public.super_admins);
  perform pg_temp.pf_chk(S3, 'има поне един супер администратор (supabase/manual/grant_super_admin.sql)', n >= 1, 'WARN', 'брой: ' || n || ' – без супер админ няма кой да управлява училищата');
  -- домейни
  n := (select count(*) from public.school_email_domains d where d.domain <> lower(btrim(d.domain)) or d.domain ~ '[@[:space:]]' or d.domain !~ '\.');
  perform pg_temp.pf_chk(S3, 'домейни с невалиден/ненормализиран вид', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.school_email_domains d where d.active
          and exists (select 1 from public.school_email_domains d2 join public.schools s2 on s2.id = d2.school_id
                       where d2.active and s2.status = 'active' and d2.school_id <> d.school_id and d2.domain = d.domain));
  perform pg_temp.pf_chk(S3, 'активен домейн в повече от едно активно училище (регистрацията се отказва; нужни са покани)', n = 0, 'WARN',
    'брой редове: ' || n || coalesce(' – ' || (select string_agg(distinct domain, ', ') from public.school_email_domains d where d.active
        and exists (select 1 from public.school_email_domains d2 where d2.active and d2.school_id <> d.school_id and d2.domain = d.domain)), ''));
  n := (select count(*) from public.school_email_domains where allow_subdomains and active);
  perform pg_temp.pf(S3, 'домейни с разрешени поддомейни (само ако е нужно)', case when n > 0 then 'WARN' else 'OK' end, 'брой: ' || n);
  perform pg_temp.pf_chk(S3, 'първоначалното училище има домейн', exists (select 1 from public.school_email_domains where school_id = v_initial and active), 'WARN');
  -- покани
  n := (select count(*) from public.school_invites where status = 'pending' and expires_at <= now());
  perform pg_temp.pf(S3, 'изтекли покани още в статус pending (нормално; не се използват)', 'INFO', 'брой: ' || n);
  -- график
  n := (select count(*) from public.schools s where not exists (select 1 from public.school_schedule_settings x where x.school_id = s.id));
  perform pg_temp.pf_chk(S3, 'училища без настройки на графика', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.schools s where not exists (select 1 from public.school_intervals i where i.school_id = s.id));
  perform pg_temp.pf_chk(S3, 'училища без интервали', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.school_schedule_settings x where x.mode = 'two_shifts'
          and (select count(*) from public.school_intervals i where i.school_id = x.school_id and i.shift = 1) <> 7
           or x.mode = 'two_shifts' and (select count(*) from public.school_intervals i where i.school_id = x.school_id and i.shift = 2) <> 7);
  perform pg_temp.pf_chk(S3, 'режим „две смени“ с различно от 7+7 интервала', n = 0, 'ERROR', 'брой: ' || n);
  n := (select count(*) from public.consultations c where not exists (select 1 from public.school_intervals i
         where i.school_id = c.school_id and i.shift = c.shift and i.position = c.hour));
  perform pg_temp.pf_chk(S3, 'консултации с час/смяна без интервал (стари невалидни редове – непроменени, не се трият)', n = 0, 'WARN', 'брой: ' || n);
  -- ПРЕДИ/СЛЕД одит
  for r in
    select b.table_name, b.row_count nb, a.row_count na
      from public.multi_school_audit b
      join public.multi_school_audit a on a.run_id = b.run_id and a.table_name = b.table_name and a.phase = 'after'
     where b.phase = 'before' and b.run_id = (select run_id from public.multi_school_audit where phase = 'before' order by id desc limit 1)
  loop
    perform pg_temp.pf_chk(S3, 'одит ПРЕДИ=СЛЕД (последно изпълнение на 20261012): ' || r.table_name, r.nb = r.na, 'ERROR', r.nb || ' -> ' || r.na);
  end loop;

  -- ===================== 4. СЛЕД: сигурност (grants) =====================
  n := (select count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon');
  perform pg_temp.pf_chk(S4, 'anon няма права върху таблици в public', n = 0, 'ERROR', 'брой грантове: ' || n);
  n := (select count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'authenticated'
          and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES')
          and not (table_name = 'classes' and privilege_type = 'DELETE')
          and not (table_name = 'consultations' and privilege_type = 'DELETE'));
  perform pg_temp.pf_chk(S4, 'authenticated пише директно само: DELETE върху classes/consultations (+ teachers.name по колона)', n = 0, 'ERROR', 'неочаквани грантове: ' || n);
  n := (select count(*) from information_schema.column_privileges where table_schema = 'public' and grantee in ('authenticated', 'anon')
          and privilege_type in ('UPDATE', 'INSERT') and not (table_name = 'teachers' and column_name = 'name' and grantee = 'authenticated'));
  perform pg_temp.pf_chk(S4, 'колонни права за запис: само teachers.name', n = 0, 'ERROR', 'неочаквани: ' || n);
  n := (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.prosecdef and p.prorettype <> 'trigger'::regtype
           and has_function_privilege('anon', p.oid, 'execute'));
  perform pg_temp.pf_chk(S4, 'anon няма EXECUTE върху SECURITY DEFINER функции', n = 0, 'ERROR',
    'брой: ' || n || coalesce(' – ' || (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.prosecdef and p.prorettype <> 'trigger'::regtype and has_function_privilege('anon', p.oid, 'execute')), ''));
  n := (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.prosecdef and not exists (select 1 from pg_options_to_table(p.proconfig) o where o.option_name = 'search_path'));
  perform pg_temp.pf_chk(S4, 'всички SECURITY DEFINER функции имат фиксиран search_path', n = 0, 'ERROR',
    'без search_path: ' || n || coalesce(' – ' || (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.prosecdef and not exists (select 1 from pg_options_to_table(p.proconfig) o where o.option_name = 'search_path')), ''));
  n := (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.proname like '\_%' and has_function_privilege('authenticated', p.oid, 'execute'));
  perform pg_temp.pf_chk(S4, 'вътрешните функции (_име) не са достъпни за authenticated', n = 0, 'WARN',
    'брой: ' || n || coalesce(' – ' || (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.proname like '\_%' and has_function_privilege('authenticated', p.oid, 'execute')), '') ||
         ' (legacy от v2.8 – не изтича данни на училища)');
  foreach t in array array['get_my_context','save_consultation','get_school_schedule','admin_add_domain','super_list_schools'] loop
    perform pg_temp.pf_chk(S4, 'authenticated има EXECUTE: ' || t,
      (select bool_and(has_function_privilege('authenticated', p.oid, 'execute')) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public' and p.proname = t), 'ERROR');
  end loop;
  -- Реалният Auth (GoTrue) извиква handle_new_user/триггерите като собственик на тригера; hook-ът е по желание
  perform pg_temp.pf(S4, 'Auth hook „Before User Created“ (по избор)', 'INFO',
    'функцията public.hook_before_user_created съществува: ' || (to_regprocedure('public.hook_before_user_created(jsonb)') is not null)::text ||
    '; включването е в Dashboard -> Authentication -> Hooks (НЕ е задължително – trigger-ът върху auth.users вече отказва)');
end
$pf$;

select section as "раздел", check_name as "проверка", status as "статус", detail as "детайл"
  from pf_result
 order by n;

-- Обобщение (втори набор – някои клиенти показват само последния резултат):
select count(*) filter (where status = 'ERROR') as errors, count(*) filter (where status = 'WARN') as warnings,
       count(*) filter (where status = 'OK') as ok, count(*) filter (where status = 'INFO') as info,
       case when to_regclass('public.schools') is null then 'PRE-MIGRATION (миграциите още не са приложени – вижте INFO/WARN горе)'
            when count(*) filter (where status = 'ERROR') > 0 then 'NOT READY'
            when count(*) filter (where status = 'WARN') > 0 then 'READY WITH WARNINGS' else 'READY' end as verdict
  from pf_result;
