# v3.1 – Регистрация, роли и bootstrap на първия супер админ

## Как работи регистрацията (реалният код)
1. `js/app.js submitAuth()` → `js/auth.js signUp(name,email,password)` → `sb.auth.signUp({email,password,options:{data:{name}}})`. Клиентът НЕ праща role/school_id (ако ги прати в metadata, се игнорират).
2. В `auth.users`: BEFORE INSERT/UPDATE OF email `auth_users_email_domain` → `enforce_email_domain()`; по избор Auth hook `hook_before_user_created`.
3. AFTER INSERT `on_auth_user_created` → `handle_new_user()`: определя училището с `resolve_registration_school` (покана > домейн; `ambiguous`/`inactive`/`none` → CS001), създава `teachers` + `school_memberships` (роля винаги `teacher`).
4. След вход: `get_my_context()` връща роля и училище от базата. Супер админ без избрано училище → екран „Училища“.

## Конфликт и минимална промяна
Конфликт: всички гореспоменати проверки отказваха имейл извън училищен домейн, а `super_admins` има FK към `auth.users` → първият супер админ не можеше да се създаде.
Промяна (миграция `20261016000000_super_admin_bootstrap.sql`, идемпотентна, старите не са пипани):
- нова таблица `public.super_admin_invites` (точен имейл; RLS без политики; достъп само през RPC). Нова таблица е нужна, защото `super_admins` изисква съществуващ Auth user, а `school_invites` е училищна и само за `teacher`.
- `enforce_email_domain`, `handle_new_user`, `hook_before_user_created` допускат и имейл с pending покана за супер админ; `resolve_registration_school` е непроменена. Обикновен `@edu.mon.bg` пак получава CS001.
- „Admin domain“ като таблица НЕ е нужен: права дава само `super_admins`; домейнът никога не е достатъчен.
- Супер админ няма принудително училище/`teachers` ред (`teachers.school_id` е NOT NULL).

## Bootstrap (еднократно, ръчно)
`supabase/manual/bootstrap_first_super_admin.sql` → `select public.bootstrap_first_super_admin('имейл')` (недостъпна за anon/authenticated; работи само докато няма супер админ).
- Auth user съществува → директен запис с реалния му id (`GRANTED`).
- Не съществува → `INVITED` (72 ч.); създайте потребителя в Dashboard → Authentication → Users → Add user с ТОЧНО този имейл, Auto Confirm.
Риск: докато поканата е pending, който регистрира този имейл получава права → създайте профила веднага, дръжте включено потвърждение на имейла.

## Добавяне на админи
- Супер админ: екран „Училища“ → „Супер администратори“ (`super_add_super_admin`, `super_remove_super_admin`, не и последния).
- Училищен админ с имейл извън домейна (напр. `admin@edu.mon.bg`): супер админ → Управлявай → покана → след регистрация „Назначи за администратор“.

## Тестове
`supabase/tests/v3_1_auth_bootstrap_checks.sql` (49 проверки: 11-те сценария + атаки), `local-harness/*`, `node --test` (138). Всичко е на локален PostgreSQL stub – **НЕПРОВЕРЕНО В REAL SUPABASE**.

## Проверка на реалната база (пуснете в SQL Editor, read-only)
```sql
select tgname, tgenabled from pg_trigger where tgrelid='auth.users'::regclass and not tgisinternal;
select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and proname in ('resolve_registration_school','enforce_email_domain','handle_new_user','hook_before_user_created');
select count(*) from public.super_admins;
```
Ред на прилагане: `manual/preflight_multi_school.sql` → миграция 20261016 → bootstrap скрипт.
