-- =====================================================================
-- РЪЧНО назначаване на СУПЕР АДМИНИСТРАТОР (изпълнява се в Supabase SQL Editor като собственик).
-- НЕ е миграция и НЕ се пуска автоматично; имейлът не бива да стои в история на миграциите.
--
-- Предпоставки: потребителят вече е регистриран (има ред в auth.users) и е потвърдил имейла си.
-- 1) Заменете REPLACE_WITH_EMAIL с точния имейл. 2) Пуснете скрипта. 3) Потребителят излиза и влиза отново.
-- Ролята „супер админ“ е ГЛОБАЛНА (public.super_admins) и е независима от училищната роля.
-- Училищни админи и учители НЕ могат да я дадат – няма клиентски път (RLS/GRANT го забраняват).
-- =====================================================================
do $$
declare
  v_email text := lower(btrim('REPLACE_WITH_EMAIL'));
  v_user  uuid;
begin
  if v_email = 'replace_with_email' then
    raise exception 'Първо заменете REPLACE_WITH_EMAIL с реалния имейл.';
  end if;
  select u.id into v_user from auth.users u where lower(u.email) = v_email;
  if v_user is null then
    raise exception 'Няма регистриран потребител с имейл %. Регистрирайте го първо.', v_email;
  end if;
  insert into public.super_admins (user_id, note)
  values (v_user, 'назначен ръчно от SQL Editor на ' || to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (user_id) do nothing;
  raise notice 'Супер администратор: % (%)', v_email, v_user;
end $$;

-- Проверка (трябва да върне поне един ред):
select u.email, s.created_at from public.super_admins s join auth.users u on u.id = s.user_id order by s.created_at;
