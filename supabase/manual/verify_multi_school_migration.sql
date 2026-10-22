-- =====================================================================
-- Само за ЧЕТЕНЕ: проверка след миграциите 20261012–20261014 (SQL Editor, собственик).
-- Нищо не променя. Всички редове в колоната "ok" трябва да са true.
-- =====================================================================
select 'ПРЕДИ/СЛЕД (последно изпълнение на 20261012)' as раздел, b.table_name, b.row_count as преди, a.row_count as след,
       (b.row_count = a.row_count) as ok
  from public.multi_school_audit b
  join public.multi_school_audit a on a.run_id = b.run_id and a.table_name = b.table_name and a.phase = 'after'
 where b.phase = 'before'
   and b.run_id = (select run_id from public.multi_school_audit where phase = 'before' order by id desc limit 1)
 order by b.table_name;

select 'редове без училище' as проверка, t as таблица, n as брой, (n = 0) as ok from (
  select 'teachers' t, count(*) n from public.teachers where school_id is null
  union all select 'classes', count(*) from public.classes where school_id is null
  union all select 'consultations', count(*) from public.consultations where school_id is null
  union all select 'consultation_classes', count(*) from public.consultation_classes where school_id is null
  union all select 'group_subjects', count(*) from public.group_subjects where school_id is null
  union all select 'school_settings', count(*) from public.school_settings where school_id is null) x;

select 'връзки между различни училища' as проверка, count(*) as брой, (count(*) = 0) as ok
  from public.consultation_classes cc
  join public.consultations c on c.id = cc.consultation_id
  join public.classes k on k.id = cc.class_id
 where cc.school_id <> c.school_id or cc.school_id <> k.school_id;

select 'профили без членство' as проверка, count(*) as брой, (count(*) = 0) as ok
  from public.teachers t
 where not exists (select 1 from public.school_memberships m where m.user_id = t.id and m.school_id = t.school_id);

select 'роли teachers.role = membership.role' as проверка, count(*) as несъвпадения, (count(*) = 0) as ok
  from public.teachers t join public.school_memberships m on m.user_id = t.id and m.status = 'active'
 where t.role <> m.role;

select 'училища' as раздел, s.id, s.name, s.status,
       (select count(*) from public.teachers t where t.school_id = s.id) as учители,
       (select count(*) from public.classes k where k.school_id = s.id) as класове,
       (select count(*) from public.consultations c where c.school_id = s.id) as консултации,
       (select string_agg(d.domain, ', ') from public.school_email_domains d where d.school_id = s.id and d.active) as домейни
  from public.schools s order by s.created_at;

select 'супер администратори' as раздел, count(*) as брой from public.super_admins;

select 'график' as раздел, s.school_id, s.mode,
       (select count(*) from public.school_intervals i where i.school_id = s.school_id) as интервали
  from public.school_schedule_settings s;

select 'консултации без позиция в графика' as проверка, count(*) as брой
  from public.consultations c
 where not exists (select 1 from public.school_intervals i where i.school_id = c.school_id and i.shift = c.shift and i.position = c.hour);
