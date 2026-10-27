-- =====================================================================
-- ВРЪЩАНЕ към еднoучилищния модел (v2.9) – САМО ако в системата има ТОЧНО ЕДНО училище.
-- Изпълнява се в Supabase SQL Editor като собственик, СЛЕД което се пуска manual/rollback_restore_v29.sql
-- (връща старите функции, RLS политики и тригери). НЕ пускайте наново всички стари миграции подред:
-- 20261006 създава уникален индекс по „физически слот“, който е несъвместим с вече записани I/7 и II/1.
--
-- Скриптът НЕ ИЗТРИВА консултации, учители, класове, предмети с групи, настройки.
-- Маха само новите таблици/функции/колони за много училища. Данните за второ училище НЕ могат да се
-- запазят в едноучилищен модел – ако има второ училище, скриптът спира с грешка и не прави нищо.
--
-- ПРЕДИ ТОВА ВИНАГИ: пълно резервно копие (Dashboard -> Database -> Backups или pg_dump).
-- Алтернатива на този скрипт: възстановяване от резервното копие.
-- =====================================================================
begin;

do $$
begin
  if (select count(*) from public.schools) > 1 then
    raise exception 'Има повече от едно училище – връщането е невъзможно без загуба на данни. Спрено; нищо не е променено.';
  end if;
end $$;

-- 1. Политики на всички засегнати таблици (старите се възстановяват от миграциите)
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
            where schemaname = 'public'
              and tablename in ('teachers','classes','group_subjects','consultations','consultation_classes','school_settings')
  loop execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename); end loop;
end $$;

-- 2. Тригери върху auth.users и таблиците (старите: от 20260101…/20261010…)
drop trigger if exists auth_users_email_domain on auth.users;
drop trigger if exists on_auth_user_created on auth.users;
do $$
declare t text;
begin
  foreach t in array array['teachers','classes','group_subjects','consultations','consultation_classes','school_settings'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_set_school_id', t);
    execute format('drop trigger if exists %I on public.%I', t || '_school_immutable', t);
  end loop;
end $$;
drop trigger if exists school_memberships_sync on public.school_memberships;
drop trigger if exists schools_seed_schedule on public.schools;

-- 3. Ограничения и колони за много училища
alter table public.consultations        drop constraint if exists consultations_interval_fk;
alter table public.consultation_classes drop constraint if exists consultation_classes_class_school_fk;
alter table public.consultation_classes drop constraint if exists consultation_classes_consultation_school_fk;
alter table public.consultations        drop constraint if exists consultations_teacher_school_fk;
drop index if exists public.school_settings_school_uq, public.classes_school_name_uq, public.group_subjects_school_subject_uq;
alter table public.teachers             drop column if exists school_id cascade;
alter table public.classes              drop column if exists school_id cascade;
alter table public.group_subjects       drop column if exists school_id cascade;
alter table public.consultations        drop column if exists school_id cascade;
alter table public.consultation_classes drop column if exists school_id cascade;
alter table public.school_settings      drop column if exists school_id cascade;
alter table public.teachers             drop constraint if exists teachers_id_school_uq;
alter table public.classes              drop constraint if exists classes_id_school_uq;
alter table public.consultations        drop constraint if exists consultations_id_school_uq;

-- глобални уникалности и „един ред“ на настройките
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.classes'::regclass and contype = 'u'
                    and conname = 'classes_name_key') then
    alter table public.classes add constraint classes_name_key unique (name);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.group_subjects'::regclass and contype = 'u'
                    and conname = 'group_subjects_subject_key') then
    alter table public.group_subjects add constraint group_subjects_subject_key unique (subject);
  end if;
end $$;
alter table public.school_settings alter column id set default 1;
drop sequence if exists public.school_settings_id_seq;
update public.school_settings set id = 1 where id <> 1 and not exists (select 1 from public.school_settings where id = 1);
alter table public.school_settings drop constraint if exists school_settings_single_row;
alter table public.school_settings add constraint school_settings_single_row check (id = 1);

-- 4. Нови таблици (няма данни, които да се губят извън тези на единственото училище –
--    консултациите/учителите остават; изчезват само членства, домейни, настройки на график)
drop table if exists public.school_intervals, public.school_schedule_settings, public.school_invites,
                     public.super_admin_context, public.super_admins, public.school_email_domains,
                     public.school_memberships cascade;
drop table if exists public.super_admin_invites cascade;   -- v3.1 (20261016)
drop table if exists public.schools cascade;
-- multi_school_audit се ЗАПАЗВА (доказателство за броя записи).

-- 5. Нови функции
drop function if exists public.get_my_context(), public.set_active_school(uuid),
  public.super_list_schools(), public.super_create_school(text, text), public.super_update_school(uuid, text, text),
  public.super_set_school_admin(uuid, text, boolean), public.super_list_school_admins(uuid),
  public.admin_list_domains(uuid), public.admin_add_domain(text, boolean, uuid), public.admin_update_domain(bigint, boolean, boolean),
  public.admin_remove_domain(bigint), public.admin_invite_teacher(text, uuid), public.admin_cancel_invite(bigint),
  public.admin_set_member_role(uuid, text), public.admin_set_group_subject(text, boolean),
  public.get_school_schedule(boolean), public.admin_schedule_change_impact(text), public.admin_set_schedule_mode(text, boolean),
  public.admin_save_interval(int, int, time, time, boolean), public.admin_delete_interval(int, int),
  public.resolve_registration_school(text), public.is_super_admin(), public.is_school_admin(uuid),
  public.current_school_id(), public.normalize_domain(text), public._admin_school(), public._target_school(uuid),
  public._slot_valid(uuid, int, int), public._only_school_id(), public._set_school_id(), public._school_id_immutable(),
  public._sync_membership_to_teacher(), public._schools_seed_schedule(), public._seed_default_schedule(uuid),
  public._seed_two_shift_intervals(uuid, int), public._default_interval(int), public._default_academic_year(),
  public._is_public_mail_domain(text), public._validate_shift_intervals(uuid, int),
  public.bootstrap_first_super_admin(text, int), public.super_list_super_admins(), public.super_add_super_admin(text),
  public.super_remove_super_admin(uuid), public.super_cancel_super_admin_invite(bigint),
  public._pending_super_invite(text), public._require_super();

commit;

-- 6. СЕГА пуснете manual/rollback_restore_v29.sql (възстановява RLS, функциите и тригерите на v2.9).
--    Не забравяйте js/ да е версията от v2.9.
