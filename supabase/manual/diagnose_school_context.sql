-- =====================================================================
-- ДИАГНОСТИКА (само четене): защо даден потребител вижда определено училище?
-- Пуснете в Supabase SQL Editor. Нищо не променя.
-- =====================================================================
-- 1) Училища и техните домейни (един домейн трябва да е само при ЕДНО активно училище)
select s.id, s.name, s.status, d.domain, d.allow_subdomains, d.active
  from public.schools s left join public.school_email_domains d on d.school_id = s.id order by s.name, d.domain;

-- 2) Към кое училище принадлежи всеки потребител и дали е супер админ.
--    Ако потребител @paisii.info има super_admin = true, той получава ИЗБРАНОТО от него училище (колона 'избрано'), не членството си.
select u.email, m.role as роля_в_училище, s.name as училище_по_членство, m.status,
       (sa.user_id is not null) as super_admin, cs.name as избрано_от_супер_админ
  from auth.users u
  left join public.school_memberships m on m.user_id = u.id
  left join public.schools s on s.id = m.school_id
  left join public.super_admins sa on sa.user_id = u.id
  left join public.super_admin_context c on c.user_id = u.id
  left join public.schools cs on cs.id = c.school_id
 order by u.email;

-- 3) Разминаване между името на училището и неговите настройки (header-ът до v3.1.0 четеше settings.school_name)
select s.id, s.name as име_в_schools, t.school_name as име_в_настройки
  from public.schools s left join public.school_settings t on t.school_id = s.id
 where t.school_name is distinct from s.name;

-- 4) Потребители с повече от едно активно членство (не бива)
select user_id, count(*) from public.school_memberships where status = 'active' group by 1 having count(*) > 1;
