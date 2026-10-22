#!/bin/bash
# ОДИТ (v3.0, финален): запазване на данните при миграция върху „мръсна“ v2.9 база + проверка, че preflight хваща повреди.
# Локален PostgreSQL със Supabase stub – НЕ е реален Supabase.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/lib.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✔ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✘ $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (очаквано '$3', получено '$2')"; fi; }

mkdb ms_au >/dev/null 2>&1; apply ms_au "$OLD_MIGRATIONS" || exit 1
# стари индекси, каквито може да има реалната база
psql -d ms_au -q -c "create unique index legacy_classes_lower_uq on public.classes(lower(name));" 
$P -d ms_au -f "$HERE/seed_old.sql"
# стари редове с невалиден час (v1.7) – трябва да останат непроменени
psql -d ms_au -q -c "set session_replication_role = replica;
  insert into public.consultations(teacher_id,day,shift,hour,subject,location) values ('00000000-0000-0000-0000-0000000000b3',4,1,8,'Стар час 8','каб. 9'),('00000000-0000-0000-0000-0000000000b3',4,2,9,'Стар час 9','каб. 9');"
SNAP="select md5(string_agg(id::text||'|'||teacher_id::text||'|'||day||'|'||shift||'|'||hour||'|'||subject||'|'||coalesce(location,''), ',' order by id)) from public.consultations"
SNAP_CC="select md5(string_agg(consultation_id||'|'||class_id, ',' order by consultation_id, class_id)) from public.consultation_classes"
SNAP_T="select md5(string_agg(id::text||'|'||name||'|'||role, ',' order by id)) from public.teachers"
SNAP_K="select md5(string_agg(id::text||'|'||name, ',' order by id)) from public.classes"
SNAP_G="select md5(string_agg(id::text||'|'||subject||'|'||enabled, ',' order by id)) from public.group_subjects"
before_c=$(q ms_au "$SNAP"); before_cc=$(q ms_au "$SNAP_CC"); before_t=$(q ms_au "$SNAP_T"); before_k=$(q ms_au "$SNAP_K"); before_g=$(q ms_au "$SNAP_G")
[ -n "$before_cc" ] && [ "$before_cc" != "" ] && ok "снимката на връзките не е празна" || bad "снимката на връзките е празна (безсмислена проверка)"
n_c=$(q ms_au "select count(*) from public.consultations"); n_cc=$(q ms_au "select count(*) from public.consultation_classes")
echo "== Миграция върху стари данни (+2 стари невалидни часа, +стар unique индекс)"
apply ms_au "$NEW_MIGRATIONS" && ok "всички 4 миграции се прилагат" || bad "миграциите се провалиха"
chk "консултации: ID/учител/ден/смяна/час/предмет/място непроменени (md5)" "$(q ms_au "$SNAP")" "$before_c"
chk "връзки консултация-клас непроменени (md5)" "$(q ms_au "$SNAP_CC")" "$before_cc"
chk "учители: ID/име/роля непроменени (md5)" "$(q ms_au "$SNAP_T")" "$before_t"
chk "класове: ID/име непроменени (md5)" "$(q ms_au "$SNAP_K")" "$before_k"
chk "предмети с групи непроменени (md5)" "$(q ms_au "$SNAP_G")" "$before_g"
chk "брой консултации" "$(q ms_au "select count(*) from public.consultations")" "$n_c"
chk "брой връзки" "$(q ms_au "select count(*) from public.consultation_classes")" "$n_cc"
chk "стар час 8 остава (shift 1, hour 8)" "$(q ms_au "select count(*) from public.consultations where shift=1 and hour=8 and subject='Стар час 8'")" "1"
chk "стар час 9 остава (shift 2, hour 9)" "$(q ms_au "select count(*) from public.consultations where shift=2 and hour=9 and subject='Стар час 9'")" "1"
chk "точно едно училище" "$(q ms_au "select count(*) from public.schools")" "1"
chk "първоначалното училище е с фиксирания id и името от настройките" "$(q ms_au "select count(*) from public.schools s join public.school_settings x on x.school_id=s.id where s.id='00000000-0000-4000-8000-000000000001' and s.name=x.school_name")" "1"
chk "членства: по едно на профил (без дубликати)" "$(q ms_au "select count(*)||'/'||count(distinct user_id) from public.school_memberships")" "4/4"
chk "админът остава админ на училището" "$(q ms_au "select count(*) from public.school_memberships where role='admin' and user_id='00000000-0000-0000-0000-0000000000a1'")" "1"
chk "няма автоматично назначен супер админ" "$(q ms_au "select count(*) from public.super_admins")" "0"
chk "остатъчен глобален unique индекс е премахнат от 20261015" "$(q ms_au "select count(*) from pg_indexes where tablename='classes' and indexname='legacy_classes_lower_uq'")" "0"
echo "== Повторно прилагане (идемпотентност)"
apply ms_au "$NEW_MIGRATIONS" && ok "повторно прилагане без грешка" || bad "повторното прилагане се провали"
chk "след повторно: брой консултации" "$(q ms_au "select count(*) from public.consultations")" "$n_c"
chk "след повторно: още едно училище няма" "$(q ms_au "select count(*) from public.schools")" "1"
chk "след повторно: членства" "$(q ms_au "select count(*) from public.school_memberships")" "4"
echo "== preflight върху мигрирана база"
OUT=$(psql -d ms_au -At -F'|' -f "$HERE/../../manual/preflight_multi_school.sql" 2>&1)
ERRS=$(echo "$OUT" | grep -c '|ERROR|')
chk "preflight: 0 ERROR" "$ERRS" "0"
echo "$OUT" | grep '|WARN|' | sed 's/^/     WARN: /'
echo "== preflight хваща повреди (в копие на базата)"
dropdb --if-exists ms_au2 2>/dev/null; createdb -T ms_au ms_au2
psql -d ms_au2 -q -c "set session_replication_role = replica;
  insert into public.schools(id,name) values ('00000000-0000-4000-8000-0000000000b2','Второ');
  insert into public.classes(name,school_id) values ('5Я','00000000-0000-4000-8000-0000000000b2');
  insert into public.consultation_classes(consultation_id,class_id,school_id) select c.id,(select id from public.classes where name='5Я'),c.school_id from public.consultations c limit 1;
  update public.consultations set school_id='00000000-0000-4000-8000-0000000000b2' where id=(select min(id) from public.consultations);
  update public.teachers set role='admin' where id='00000000-0000-0000-0000-0000000000b1';
  insert into public.school_email_domains(school_id,domain) values ('00000000-0000-4000-8000-0000000000b2','paisii.info');"
OUT2=$(psql -d ms_au2 -At -F'|' -f "$HERE/../../manual/preflight_multi_school.sql" 2>&1)
for pat in "РАЗЛИЧНИ училища" "консултации с учител от друго училище" "teachers.role се различава" "активен домейн в повече от едно" "училища без настройки"; do
  if echo "$OUT2" | grep -q "$pat.*|\(ERROR\|WARN\)|"; then ok "хванато: $pat"; else bad "НЕ е хванато: $pat"; fi
done
echo "== Одит: припокриване на домейни между училища (админ не може да „открадне“ чужд домейн)"
dropdb --if-exists ms_au3 2>/dev/null; mkdb ms_au3 >/dev/null 2>&1; apply ms_au3 "$OLD_MIGRATIONS"; $P -d ms_au3 -f "$HERE/seed_min.sql" >/dev/null 2>&1; apply ms_au3 "$NEW_MIGRATIONS"
psql -d ms_au3 -q -c "insert into public.super_admins(user_id) values ('00000000-0000-0000-0000-0000000000b3'); update public.school_memberships set role='admin' where user_id='00000000-0000-0000-0000-0000000000a1';"
asu() { psql -d ms_au3 -Atq -c "set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$1\",\"role\":\"authenticated\"}',false) \gset
$2" 2>&1; }
SUP=00000000-0000-0000-0000-0000000000b3; ADM=00000000-0000-0000-0000-0000000000a1
psql -d ms_au3 -Atq -c "set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$SUP\",\"role\":\"authenticated\"}',false); select public.super_create_school('Училище Б','school-b.example.bg');" >/dev/null
try() { psql -d ms_au3 -Atq -c "set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$ADM\",\"role\":\"authenticated\"}',false); $1" 2>&1 | grep -c "припокрива\|друго училище"; }
chk "родителски домейн с поддомейни се отказва" "$(try "select public.admin_add_domain('example.bg', true, null);")" "1"
chk "точният чужд домейн се отказва" "$(try "select public.admin_add_domain('school-b.example.bg', false, null);")" "1"
chk "родителски домейн БЕЗ поддомейни е позволен" "$(try "select public.admin_add_domain('example.bg', false, null);")" "0"
chk "включване на поддомейни по-късно се отказва" "$(try "select public.admin_update_domain((select id from public.school_email_domains where domain='example.bg'), true, true);")" "1"
chk "публичен домейн се отказва" "$(psql -d ms_au3 -Atq -c "set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$ADM\",\"role\":\"authenticated\"}',false); select public.admin_add_domain('gmail.com', false, null);" 2>&1 | grep -c 'Публични')" "1"
chk "регистрацията за school-b.example.bg остава еднозначна (Б)" "$(psql -d ms_au3 -Atq -c "select reason from public.resolve_registration_school('t@school-b.example.bg')")" "domain"
echo "== Одит: покана не „краде“ чужд домейн"
chk "покана за имейл от домейна на Б (от админ на А) се отказва" "$(try "select public.admin_invite_teacher('new@school-b.example.bg', null);")" "1"
chk "покана за външен имейл (gmail) е позволена" "$(try "select public.admin_invite_teacher('ext.teacher@gmail.com', null);")" "0"
chk "покана за имейл от собствения домейн е позволена" "$(try "select public.admin_invite_teacher('own@paisii.info', null);")" "0"
echo; echo "РЕЗУЛТАТ ОДИТ: преминали $PASS, паднали $FAIL"; [ "$FAIL" = 0 ]
