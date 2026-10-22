-- РЪЧНО отнемане на роля „супер администратор“ (SQL Editor, собственик). Заменете имейла.
-- Внимание: не оставяйте системата без нито един супер администратор.
do $$
declare v_email text := lower(btrim('REPLACE_WITH_EMAIL')); v_user uuid;
begin
  select u.id into v_user from auth.users u where lower(u.email) = v_email;
  if v_user is null then raise exception 'Няма потребител с имейл %.', v_email; end if;
  if (select count(*) from public.super_admins) <= 1 and exists (select 1 from public.super_admins where user_id = v_user) then
    raise exception 'Това е последният супер администратор – първо назначете друг.';
  end if;
  delete from public.super_admins where user_id = v_user;
  delete from public.super_admin_context where user_id = v_user;
end $$;
