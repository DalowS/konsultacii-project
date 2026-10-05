# График за консултации (v2.0)

Училищен график за консултации – статичен frontend (GitHub Pages) + Supabase (Auth, PostgreSQL, RLS, Realtime).

```
GitHub Pages (HTML/CSS/JS) --HTTPS--> Supabase JS --> Auth + PostgreSQL (RLS, RPC) + Realtime
```
GitHub не е база данни. Всички данни са в Supabase.

## Структура
`index.html`, `css/style.css`, `js/{config,logic,supabase,storage,auth,app}.js`, `supabase/migrations/*.sql`, `tests/`.

## Настройка на Supabase
1. В **SQL Editor** изпълнете `supabase/migrations/20260101000000_secure_consultations.sql` (идемпотентна; предполага вече създадените таблици).
2. **Authentication → Providers → Email**: решете дали искате потвърждение по имейл. **Препоръка:** след като учителите са се регистрирали, изключете „Allow new users to sign up“ – иначе всеки с адреса може да си направи профил.
3. **Authentication → URL Configuration**: Site URL = адресът на GitHub Pages.
4. **Project Settings → API**: копирайте **Publishable key** (`sb_publishable_…`) в `js/config.js`. Никога не слагайте secret/service_role ключ.
5. Админът е `s.dalov98@gmail.com` (`teachers.role='admin'`). Други админи – от „Админ панел → Потребители“.

## GitHub Pages
Качете файловете в репозитори → Settings → Pages → Deploy from branch (`main`, `/root`). Може да се отвори и локално през `python3 -m http.server`.

## Тестове
`npm test` (автоматични); ръчни – `TESTING.md`.

## Сигурност
- Publishable key е публичен по дизайн; защитата е RLS + RPC.
- Запис на консултации само през `save_consultation` (атомарно, с проверка за конфликти).
- Учителите не могат да сменят роля, да редактират/трият чужди записи, да пишат в classes/group_subjects.
- Няма парола/секрет в JS. Потребителският текст се ескейпва.
- Миграция от v1.7: Админ панел → „Импорт на локални данни“ (от браузъра, където са били данните; учителите трябва да са регистрирани със същото име).
