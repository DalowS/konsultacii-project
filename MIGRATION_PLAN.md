# Миграция: localStorage -> Supabase (анализ и план)

## 1. Какво е намерено в v1.7
| Тема | Находка | Решение |
|---|---|---|
| localStorage | `consultations`, `currentTeacher`, `groupSubjects` | Данните са в Supabase; localStorage се чете само от еднократния импорт |
| Teacher login | Само въвеждане на име | Supabase Auth (имейл + парола) |
| Admin | `adminPassword: "admin123"` в JS | Премахнато; роля = `teachers.role` |
| Конфликти | Само в клиента (`saveConsultation`, `openAddModal`) | Сървърен RPC `save_consultation` със заключване на слота |
| Multi-class | `classes` масив/CSV в запис | Релация `consultation_classes` |
| ID | `createId()` в JS | `bigint identity` от базата |
| `showTeacherScreen()` | Намерена е **една** дефиниция (ред 1288); дублиране няма | Една дефиниция в `app.js` |
| Статистика | Вече броеше логически клетки | Запазено (`countOccupiedCells` е тестван) |
| Clear all | `prompt("ИЗТРИЙ")` без backup | Admin RPC + потвърждение + автоматичен JSON backup |
| Допълнително | Конфликтът на учител се проверяваше срещу `currentTeacher` дори при админ редакция | Сървърът ползва реалния собственик на записа |
| Допълнително | Само основният клас се проверяваше за конфликт | Сървърът проверява **всеки** избран клас |

## 2. Запазено
Целият UI/CSS (`css/style.css` е извлечен без промени), рендерирането на графика, модалите, филтрите, CSV, печат, статистика, предмети с групи, текстове на български.

## 3. Правила за конфликти (пренесени от клиента)
- Един учител – не повече от една консултация на слот (ден+смяна+час).
- Клас със запис в слота: нов запис е позволен само ако предметът е „групов“ (`group_subjects.enabled`), съвпада (без значение от регистъра) с останалите, броят е <2 и местата са различни.
- Групов предмет изисква място.
- Конкурентност: `pg_advisory_xact_lock` за слота + уникален индекс `(teacher_id, day, shift, hour)`.

## 4. Mapping
`consultation{id, teacherId, teacherName, day(име), shift, hour, subject, location, classes[]}` ⇄ `consultations(id, teacher_id, day 1..5, shift, hour, subject, location)` + `consultation_classes(consultation_id, class_id)`; имената идват с един select с embed (`teachers(name)`, `consultation_classes(classes(name))`), със странициране по 1000.

## 5. Сигурност
- Запис в `consultations`/`consultation_classes` е възможен **само през RPC** (няма INSERT/UPDATE политики + REVOKE).
- Изтриване: собственик или админ (RLS). Роля не може да се променя от учител (trigger); последният админ не може да бъде свален.
- `anon` няма достъп до таблиците; `TRUNCATE` е отнето.
- Роля никога не се взима от user metadata.
- XSS: целият потребителски текст минава през `escapeHtml`; CSV – защита от формули.
- Във frontend има само publishable key.

## 6. Състояние по фази
1 Анализ ✔ · 2 Supabase подготовка ✔ · 3 Auth ✔ · 4 Storage ✔ · 5 Нормализация ✔ · 6 Сървърни конфликти ✔ · 7 Realtime ✔ · 8 Импорт ✔ · 9 Тестове: автоматични ✔, ръчни – `TESTING.md` · 10 Deploy: `README.md`

> Част от кода (SQL, Supabase заявки, realtime) **не е изпълняван срещу реалния проект** – вж. `TESTING.md`.
