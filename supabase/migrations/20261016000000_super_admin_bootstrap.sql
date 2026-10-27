-- =====================================================================
-- v3.1 – Bootstrap на първия супер админ + контролирано добавяне на супер админи
--
-- ПРОБЛЕМ: триггерите върху auth.users (auth_users_email_domain, on_auth_user_created) и по избор
-- hook_before_user_created допускат само имейли от домейн на активно училище или с pending покана.
-- Затова, след изтриване на единствения Auth потребител, не може да се създаде нов (дори супер админ
-- с имейл @edu.mon.bg, който не е училищен домейн) -> CS001.
--
-- РЕШЕНИЕ (минимална промяна, нищо не се изключва):
--   * НОВА таблица public.super_admin_invites – „упълномощен имейл“ за супер админ. Нужна е, защото
--     public.super_admins има FK към auth.users (не може да се пише за още несъществуващ потребител),
--     а public.school_invites е училищна и носи само роля teacher. Домейнът НИКОГА не дава права:
--     упълномощава се ТОЧЕН имейл, от съществуващ супер админ или от собственика на базата (bootstrap).
--   * enforce_email_domain / handle_new_user / hook_before_user_created: допълнително допускат имейл
--     с pending super_admin_invite. При него се записва ред в public.super_admins (потребителят вече
--     реално съществува в auth.users – AFTER INSERT) и поканата става 'used'. Училищната логика
--     (resolve_registration_school) НЕ се променя; за обикновен @edu.mon.bg потребител пак е CS001.
--   * public.bootstrap_first_super_admin(email) – само за собственика на базата (SQL Editor), работи
--     САМО докато няма нито един супер админ.
--   * RPC за съществуващ супер админ: super_list_super_admins, super_add_super_admin,
--     super_remove_super_admin (не и последния), super_cancel_super_admin_invite.
-- Идемпотентна е. Не променя данни и не пипа старите миграции, RLS или съществуващите таблици.
-- =====================================================================
begin;

-- ---------- 1. Таблица на упълномощените имейли -----------------------------
create table if not exists public.super_admin_invites (
  id         bigint generated always as identity primary key,
  email      text not null,
  status     text not null default 'pending',
  note       text,
  expires_at timestamptz not null default (now() + interval '7 days'),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,   -- null = bootstrap от собственика на БД
  used_by    uuid references auth.users (id) on delete set null,
  used_at    timestamptz,
  constraint super_admin_invites_email  check (email = lower(btrim(email)) and email ~ '^[^@[:space:]]+@[^@[:space:]]+$'),
  constraint super_admin_invites_status check (status in ('pending', 'used', 'cancelled'))
);
create unique index if not exists super_admin_invites_pending_uq
  on public.super_admin_invites (email) where status = 'pending';

alter table public.super_admin_invites enable row level security;     -- без политики: достъп само през RPC
revoke all on public.super_admin_invites from public, anon, authenticated;

-- ---------- 2. Помощна: има ли валидна покана за супер админ? ---------------
create or replace function public._pending_super_invite(p_email text)
returns bigint
language sql stable security definer
set search_path = public, pg_temp
as $$
  select i.id from public.super_admin_invites i
   where i.email = lower(btrim(coalesce(p_email, ''))) and i.status = 'pending' and i.expires_at > now()
   limit 1
$$;
revoke all on function public._pending_super_invite(text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public._pending_super_invite(text) to supabase_auth_admin;
  end if;
end $$;

-- ---------- 3. enforce_email_domain: + покана за супер админ -----------------
-- (UPDATE клонът е непроменен: супер админите вече заобикалят проверката при смяна на имейл.)
create or replace function public.enforce_email_domain()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r record; v_school uuid;
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;
  select * into r from public.resolve_registration_school(new.email);
  if tg_op = 'UPDATE' then
    select m.school_id into v_school from public.school_memberships m
     where m.user_id = new.id and m.status = 'active';
    if exists (select 1 from public.super_admins s where s.user_id = new.id) then return new; end if;
    if v_school is not null and r.school_id is not distinct from v_school then return new; end if;
    raise exception 'Новият имейл не принадлежи към разрешен домейн на вашето училище.' using errcode = 'CS001';
  end if;
  if r.reason in ('invite', 'domain') then return new; end if;
  if public._pending_super_invite(new.email) is not null then return new; end if;   -- упълномощен супер админ
  raise exception '%', case r.reason
    when 'ambiguous' then 'Домейнът на имейла е свързан с повече от едно училище. Необходима е покана от администратор на училището.'
    when 'inactive'  then 'Училището за този домейн не е активно.'
    else 'Регистрацията е разрешена само с имейл от домейн, разрешен от училище.' end
    using errcode = 'CS001';
end;
$$;
revoke all on function public.enforce_email_domain() from public, anon, authenticated;

-- ---------- 4. handle_new_user: училищен път непроменен + супер админ път -----
-- Ролята в училище остава винаги 'teacher'. Супер админ право се дава САМО при pending покана за ТОЧНИЯ имейл.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_name text; r record; v_inv bigint; v_by uuid;
begin
  select * into r from public.resolve_registration_school(new.email);
  v_inv := public._pending_super_invite(new.email);
  if r.reason not in ('invite', 'domain') and v_inv is null then
    raise exception 'Регистрацията е разрешена само с имейл от домейн, разрешен от училище.' using errcode = 'CS001';
  end if;

  if r.reason in ('invite', 'domain') then
    v_name := nullif(btrim(coalesce(new.raw_user_meta_data->>'name', '')), '');
    v_name := coalesce(v_name, nullif(btrim(coalesce(new.email, '')), ''), 'Потребител');
    insert into public.teachers (id, name, role, school_id)
    values (new.id, left(v_name, 100), 'teacher', r.school_id)
    on conflict (id) do nothing;
    insert into public.school_memberships (user_id, school_id, role, status)
    values (new.id, r.school_id, 'teacher', 'active')
    on conflict (user_id, school_id) do nothing;
    if r.reason = 'invite' then
      update public.school_invites
         set status = 'used', used_by = new.id, used_at = now()
       where school_id = r.school_id and email = lower(btrim(new.email)) and status = 'pending';
    end if;
  end if;

  if v_inv is not null then
    select i.created_by into v_by from public.super_admin_invites i where i.id = v_inv;
    insert into public.super_admins (user_id, created_by, note)
    values (new.id, v_by, 'по покана за супер админ от ' || to_char(now(), 'YYYY-MM-DD HH24:MI'))
    on conflict (user_id) do nothing;
    update public.super_admin_invites
       set status = 'used', used_by = new.id, used_at = now()
     where id = v_inv;
  end if;
  return new;
end;
$$;
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- ---------- 5. Auth hook (по избор) -------------------------------------------
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare r record; v_email text := event -> 'user' ->> 'email';
begin
  select * into r from public.resolve_registration_school(v_email);
  if r.reason in ('invite', 'domain') then return '{}'::jsonb; end if;
  if public._pending_super_invite(v_email) is not null then return '{}'::jsonb; end if;
  return jsonb_build_object('error', jsonb_build_object(
    'message', case r.reason
      when 'ambiguous' then 'Домейнът на имейла е свързан с повече от едно училище. Необходима е покана.'
      when 'inactive'  then 'Училището за този домейн не е активно.'
      else 'Регистрацията е разрешена само с имейл от домейн, разрешен от училище.' end,
    'http_code', 400));
end;
$$;
revoke all on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
  end if;
end $$;

-- ---------- 6. Bootstrap на ПЪРВИЯ супер админ (само собственик на БД) -------
-- Не е достъпна за anon/authenticated. Работи само докато public.super_admins е празна.
-- Ако Auth потребителят вече съществува -> директен запис (реален id от auth.users).
-- Ако не -> pending покана за точния имейл; супер админът се създава при създаването на Auth потребителя.
create or replace function public.bootstrap_first_super_admin(p_email text, p_valid_hours int default 72)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); v_user uuid;
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'Недостатъчни права.' using errcode = 'CS001';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' or v_email = 'replace_with_email' then
    raise exception 'Невалиден имейл. Заменете REPLACE_WITH_EMAIL с реалния имейл.' using errcode = 'CS001';
  end if;
  if exists (select 1 from public.super_admins) then
    raise exception 'Вече има супер администратор. Bootstrap е позволен само за първия; следващите се добавят от супер админ през приложението.' using errcode = 'CS001';
  end if;
  if p_valid_hours is null or p_valid_hours < 1 or p_valid_hours > 168 then
    raise exception 'Валидността трябва да е между 1 и 168 часа.' using errcode = 'CS001';
  end if;

  select u.id into v_user from auth.users u where lower(u.email) = v_email;
  if v_user is not null then
    insert into public.super_admins (user_id, note)
    values (v_user, 'bootstrap от SQL Editor на ' || to_char(now(), 'YYYY-MM-DD HH24:MI'))
    on conflict (user_id) do nothing;
    return 'GRANTED: ' || v_email || ' е супер администратор (съществуващ Auth потребител ' || v_user || ').';
  end if;

  update public.super_admin_invites set status = 'cancelled' where email = v_email and status = 'pending';
  insert into public.super_admin_invites (email, note, expires_at)
  values (v_email, 'bootstrap от SQL Editor', now() + make_interval(hours => p_valid_hours));
  return 'INVITED: ' || v_email || ' е упълномощен за ' || p_valid_hours
         || ' ч. Сега създайте Auth потребителя с ТОЧНО този имейл (Dashboard -> Authentication -> Users -> Add user, Auto Confirm).';
end;
$$;
revoke all on function public.bootstrap_first_super_admin(text, int) from public, anon, authenticated;

-- ---------- 7. RPC за съществуващ супер админ -------------------------------
create or replace function public._require_super()
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_super_admin() then
    raise exception 'Само супер администратор може да управлява супер администратори.' using errcode = 'CS001';
  end if;
end;
$$;
revoke all on function public._require_super() from public, anon, authenticated;

create or replace function public.super_list_super_admins()
returns table (kind text, user_id uuid, invite_id bigint, email text, status text,
               created_at timestamptz, expires_at timestamptz, is_me boolean)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_super();
  return query
    select 'admin'::text, s.user_id, null::bigint, u.email::text, 'active'::text, s.created_at,
           null::timestamptz, (s.user_id = auth.uid())
      from public.super_admins s join auth.users u on u.id = s.user_id
    union all
    select 'invite'::text, null::uuid, i.id, i.email, case when i.expires_at > now() then 'pending' else 'expired' end,
           i.created_at, i.expires_at, false
      from public.super_admin_invites i where i.status = 'pending'
    order by 1, 6;
end;
$$;
revoke all on function public.super_list_super_admins() from public, anon;
grant execute on function public.super_list_super_admins() to authenticated;

create or replace function public.super_add_super_admin(p_email text)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); v_user uuid;
begin
  perform public._require_super();
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    raise exception 'Невалиден имейл.' using errcode = 'CS001';
  end if;
  select u.id into v_user from auth.users u where lower(u.email) = v_email;
  if v_user is not null then
    if exists (select 1 from public.super_admins s where s.user_id = v_user) then
      raise exception 'Потребителят вече е супер администратор.' using errcode = 'CS001';
    end if;
    insert into public.super_admins (user_id, created_by, note)
    values (v_user, auth.uid(), 'добавен от супер админ на ' || to_char(now(), 'YYYY-MM-DD HH24:MI'));
    return 'granted';
  end if;
  update public.super_admin_invites set status = 'cancelled' where email = v_email and status = 'pending';
  insert into public.super_admin_invites (email, created_by) values (v_email, auth.uid());
  return 'invited';
end;
$$;
revoke all on function public.super_add_super_admin(text) from public, anon;
grant execute on function public.super_add_super_admin(text) to authenticated;

create or replace function public.super_remove_super_admin(p_user uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_super();
  perform 1 from public.super_admins s where s.user_id = p_user for update;
  if not found then
    raise exception 'Потребителят не е супер администратор.' using errcode = 'CS001';
  end if;
  if (select count(*) from public.super_admins) <= 1 then
    raise exception 'Не може да се премахне последният супер администратор.' using errcode = 'CS001';
  end if;
  delete from public.super_admins where user_id = p_user;
  delete from public.super_admin_context where user_id = p_user;
end;
$$;
revoke all on function public.super_remove_super_admin(uuid) from public, anon;
grant execute on function public.super_remove_super_admin(uuid) to authenticated;

create or replace function public.super_cancel_super_admin_invite(p_id bigint)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_super();
  update public.super_admin_invites set status = 'cancelled' where id = p_id and status = 'pending';
  if not found then
    raise exception 'Поканата не е намерена или не е активна.' using errcode = 'CS001';
  end if;
end;
$$;
revoke all on function public.super_cancel_super_admin_invite(bigint) from public, anon;
grant execute on function public.super_cancel_super_admin_invite(bigint) to authenticated;

-- ---------- 8. Проверка „СЛЕД“ (при разлика – изключение = откат) -----------
do $$
begin
  if to_regclass('public.super_admin_invites') is null
     or to_regprocedure('public.bootstrap_first_super_admin(text,integer)') is null
     or to_regprocedure('public.super_add_super_admin(text)') is null then
    raise exception 'v3.1: липсват очаквани обекти – откат.';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'auth_users_email_domain' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created' and not tgisinternal) then
    raise exception 'v3.1: триггерите върху auth.users липсват – откат.';
  end if;
  if (select relrowsecurity from pg_class where oid = 'public.super_admin_invites'::regclass) is not true then
    raise exception 'v3.1: RLS върху super_admin_invites не е включен – откат.';
  end if;
end $$;

commit;
