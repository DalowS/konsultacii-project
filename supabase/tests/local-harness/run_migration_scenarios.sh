#!/bin/bash
# Сценарии за миграцията на данните (ИЗПЪЛНЯВАТ СЕ реално на локален PostgreSQL със Supabase стъб).
source "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0
ok()  { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  ✔ $1"; else FAIL=$((FAIL+1)); echo "  ✘ $1  [$3]"; fi; }
eq()  { [ "$2" = "$3" ] && ok "$1" 1 || ok "$1" 0 "очаквано '$3', получено '$2'"; }
fp()  { q "$1" "select md5(string_agg(x, '|' order by x)) from (
   select concat_ws(',','c',teacher_id,day,shift,hour,subject,coalesce(location,'')) x from consultations
   union all select concat_ws(',','cc',consultation_id,class_id) from consultation_classes
   union all select concat_ws(',','k',id,name) from classes
   union all select concat_ws(',','g',subject,enabled) from group_subjects
   union all select concat_ws(',','t',id,name,role) from teachers) s"; }

echo "== Сценарий 1: стара база v2.9 с данни -> трите миграции"
mkdb ms_s1; apply ms_s1 "$OLD_MIGRATIONS"; $P -d ms_s1 -f "$HERE/seed_old.sql"
# стар запис от v1.7 с час 8 (не бива да се пипа и не бива да блокира миграцията)
q ms_s1 "set session_replication_role=replica; insert into consultations(teacher_id,day,shift,hour,subject) values ('00000000-0000-0000-0000-0000000000b1',5,1,8,'Стар час 8'); " >/dev/null
for t in teachers classes consultations consultation_classes group_subjects school_settings; do eval "B_$t=$(q ms_s1 "select count(*) from $t")"; done
FP_BEFORE=$(fp ms_s1)
apply ms_s1 "$NEW_MIGRATIONS" && ok "трите миграции се прилагат без грешка" 1 || ok "трите миграции се прилагат без грешка" 0 ""
for t in teachers classes consultations consultation_classes group_subjects school_settings; do
  eq "брой $t е непроменен" "$(q ms_s1 "select count(*) from $t")" "$(eval echo \$B_$t)"; done
eq "съдържанието на данните е непроменено (отпечатък)" "$(fp ms_s1)" "$FP_BEFORE"
eq "точно едно училище" "$(q ms_s1 "select count(*) from schools")" "1"
eq "всички учители в първоначалното училище" "$(q ms_s1 "select count(*) from teachers where school_id='00000000-0000-4000-8000-000000000001'")" "$B_teachers"
eq "всички класове в първоначалното училище" "$(q ms_s1 "select count(*) from classes where school_id='00000000-0000-4000-8000-000000000001'")" "$B_classes"
eq "всички консултации в първоначалното училище" "$(q ms_s1 "select count(*) from consultations where school_id='00000000-0000-4000-8000-000000000001'")" "$B_consultations"
eq "всички връзки консултация-клас в първоначалното училище" "$(q ms_s1 "select count(*) from consultation_classes where school_id='00000000-0000-4000-8000-000000000001'")" "$B_consultation_classes"
eq "съществуващият админ е admin на училището" "$(q ms_s1 "select m.role from school_memberships m join auth.users u on u.id=m.user_id where u.email='admin@paisii.info'")" "admin"
eq "останалите учители са teacher" "$(q ms_s1 "select count(*) from school_memberships where role='teacher'")" "3"
eq "домейнът paisii.info е на първоначалното училище" "$(q ms_s1 "select domain from school_email_domains where school_id='00000000-0000-4000-8000-000000000001'")" "paisii.info"
eq "нито един супер администратор не е назначен автоматично" "$(q ms_s1 "select count(*) from super_admins")" "0"
eq "режим на графика: две смени" "$(q ms_s1 "select mode from school_schedule_settings")" "two_shifts"
eq "14 интервала (7+7)" "$(q ms_s1 "select count(*) from school_intervals")" "14"
eq "стар запис с час 8 е запазен" "$(q ms_s1 "select count(*) from consultations where subject='Стар час 8' and hour=8")" "1"
eq "записи без съответна позиция (само диагностика): 1" "$(q ms_s1 "select count(*) from consultations c where not exists (select 1 from school_intervals i where i.school_id=c.school_id and i.shift=c.shift and i.position=c.hour)")" "1"
eq "FK към интервалите е NOT VALID (старите редове не се проверяват)" "$(q ms_s1 "select convalidated from pg_constraint where conname='consultations_interval_fk'")" "f"
eq "школски настройки пренесени (име)" "$(q ms_s1 "select school_name from school_settings")" "$(q ms_s1 "select name from schools")"
eq "audit: преди=след за всички таблици" "$(q ms_s1 "select count(*) from multi_school_audit b join multi_school_audit a on a.run_id=b.run_id and a.table_name=b.table_name and a.phase='after' where b.phase='before' and b.row_count<>a.row_count")" "0"
$P -d ms_s1 -f "$HERE/../../manual/verify_multi_school_migration.sql" >/dev/null && ok "manual/verify_multi_school_migration.sql се изпълнява" 1 || ok "verify скриптът се изпълнява" 0 ""

echo "== Сценарий 2: идемпотентност (повторно пускане)"
FP2=$(fp ms_s1); S2=$(q ms_s1 "select count(*) from school_memberships")
apply ms_s1 "$NEW_MIGRATIONS" && ok "повторно прилагане без грешка" 1 || ok "повторно прилагане без грешка" 0 ""
eq "данните са същите (отпечатък)" "$(fp ms_s1)" "$FP2"
eq "няма дублирани училища" "$(q ms_s1 "select count(*) from schools")" "1"
eq "няма дублирани домейни" "$(q ms_s1 "select count(*) from school_email_domains")" "1"
eq "няма дублирани членства" "$(q ms_s1 "select count(*) from school_memberships")" "$S2"
eq "няма дублирани интервали" "$(q ms_s1 "select count(*) from school_intervals")" "14"
# изтрит от админа домейн не се връща при повторно пускане
q ms_s1 "delete from school_email_domains" >/dev/null
apply ms_s1 "20261012000000" && eq "изтрит домейн не се възстановява при повторно пускане" "$(q ms_s1 "select count(*) from school_email_domains")" "0"

echo "== Сценарий 3: назначаване на супер админ (ръчният скрипт)"
q ms_s1 "insert into school_email_domains(school_id,domain) values ('00000000-0000-4000-8000-000000000001','paisii.info')" >/dev/null
sed "s/REPLACE_WITH_EMAIL/admin@paisii.info/" "$HERE/../../manual/grant_super_admin.sql" | $P -d ms_s1 >/dev/null 2>&1 && ok "grant_super_admin.sql назначава" 1 || ok "grant_super_admin.sql назначава" 0 ""
eq "точно един супер админ" "$(q ms_s1 "select count(*) from super_admins")" "1"
sed "s/REPLACE_WITH_EMAIL/admin@paisii.info/" "$HERE/../../manual/grant_super_admin.sql" | $P -d ms_s1 >/dev/null 2>&1 && ok "повторно пускане е безопасно" 1 || ok "повторно пускане е безопасно" 0 ""
eq "няма дубликат" "$(q ms_s1 "select count(*) from super_admins")" "1"
sed "s/REPLACE_WITH_EMAIL/nobody@paisii.info/" "$HERE/../../manual/grant_super_admin.sql" | $P -d ms_s1 >/dev/null 2>&1 && ok "непознат имейл се отказва" 0 "" || ok "непознат имейл се отказва" 1
$P -d ms_s1 -f "$HERE/../../manual/grant_super_admin.sql" >/dev/null 2>&1 && ok "неподменен шаблон се отказва" 0 "" || ok "неподменен шаблон се отказва" 1

echo "== Сценарий 4: нова (празна) инсталация – чиста верига от миграции"
mkdb ms_s4; apply ms_s4 "$OLD_MIGRATIONS $NEW_MIGRATIONS" && ok "празна база: 7 стари + 3 нови миграции" 1 || ok "празна база" 0 ""
eq "празна база: няма данни, няма училища" "$(q ms_s4 "select count(*) from schools")" "1"

echo "== Сценарий 5: гранични данни (празно име на училище в старите настройки)"
mkdb ms_s5; apply ms_s5 "$OLD_MIGRATIONS"; $P -d ms_s5 -f "$HERE/seed_old.sql"
# Подлагаме: стар unique на group_subjects се заменя; подсказваме проблем чрез невалидна стойност в school_settings.school_name (празно)
q ms_s5 "alter table school_settings drop constraint school_settings_name_len" >/dev/null
q ms_s5 "update school_settings set school_name='  '" >/dev/null
FP5=$(fp ms_s5)
apply ms_s5 "$NEW_MIGRATIONS" && ok "при празно име се използва 'Училище' (не се спира)" 1 || ok "при празно име се използва 'Училище'" 0 ""
eq "данните са цели" "$(fp ms_s5)" "$FP5"

echo "== Сценарий 6: връщане назад (rollback) с данни"
mkdb ms_s6; apply ms_s6 "$OLD_MIGRATIONS"; $P -d ms_s6 -f "$HERE/seed_old.sql"
FP6=$(fp ms_s6)
apply ms_s6 "$NEW_MIGRATIONS"
$P -d ms_s6 -f "$HERE/../../manual/rollback_multi_school.sql" >/dev/null 2>&1 && ok "rollback скриптът се изпълнява" 1 || ok "rollback скриптът се изпълнява" 0 ""
$P -d ms_s6 -f "$HERE/../../manual/rollback_restore_v29.sql" >/dev/null 2>&1 && ok "rollback_restore_v29.sql се прилага" 1 || ok "rollback_restore_v29.sql се прилага" 0 ""
eq "данните са същите след връщането (отпечатък)" "$(fp ms_s6)" "$FP6"
eq "няма таблица schools" "$(q ms_s6 "select count(*) from pg_tables where tablename='schools'")" "0"
eq "няма колона school_id" "$(q ms_s6 "select count(*) from information_schema.columns where column_name='school_id' and table_schema='public'")" "0"
eq "старият is_admin() работи (по teachers.role)" "$(q ms_s6 "set request.jwt.claims='{\"sub\":\"00000000-0000-0000-0000-0000000000a1\"}'; select public.is_admin()" | tail -1)" "t"
eq "старият save_consultation работи като учител" "$(q ms_s6 "set role authenticated; set request.jwt.claims='{\"sub\":\"00000000-0000-0000-0000-0000000000b1\"}'; select count(*) from (select public.save_consultation(null,4,1,3,'Физика','каб 9',array['6А'])) x" | tail -1)" "1"
eq "audit таблицата е запазена" "$(q ms_s6 "select count(*)>0 from multi_school_audit")" "t"
# отказ при второ училище
mkdb ms_s7; apply ms_s7 "$OLD_MIGRATIONS"; $P -d ms_s7 -f "$HERE/seed_old.sql"; apply ms_s7 "$NEW_MIGRATIONS"
q ms_s7 "insert into schools(name) values ('Второ')" >/dev/null
$P -d ms_s7 -f "$HERE/../../manual/rollback_multi_school.sql" >/dev/null 2>&1 && ok "rollback при 2 училища се отказва" 0 "" || ok "rollback при 2 училища се отказва" 1
eq "при отказ нищо не е променено (schools още съществува)" "$(q ms_s7 "select count(*) from schools")" "2"

echo; echo "РЕЗУЛТАТ: преминали $PASS, паднали $FAIL"
[ "$FAIL" = "0" ]
