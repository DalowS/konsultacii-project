/* Чиста бизнес логика без DOM/мрежа – ползва се и в браузъра, и в Node тестовете. */
(function (root) {
    const DAY_NAMES = ["Понеделник", "Вторник", "Сряда", "Четвъртък", "Петък"];

    const dayToIndex = name => DAY_NAMES.indexOf(name) + 1;          // 0 ако е невалиден
    const indexToDay = n => DAY_NAMES[Number(n) - 1] || "";

    function normalizeSubject(value) {
        return String(value || "").trim().toLocaleLowerCase("bg-BG");
    }

    function normalizeClasses(record) {
        if (Array.isArray(record.classes)) {
            return [...new Set(record.classes.map(v => String(v).trim()).filter(Boolean))];
        }
        const raw = record.classes ?? record.className ?? "";
        return [...new Set(String(raw).split(",").map(v => v.trim()).filter(Boolean))];
    }

    // 8А < 8Б < 9А < 10А (по номер на клас, после по буква)
    function compareClassNames(a, b) {
        const pa = /^(\d+)\s*(.*)$/.exec(a) || [0, 0, a];
        const pb = /^(\d+)\s*(.*)$/.exec(b) || [0, 0, b];
        return (Number(pa[1]) - Number(pb[1])) || String(pa[2]).localeCompare(String(pb[2]), "bg");
    }

    function escapeHtml(value) {
        return String(value ?? "")
            .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;").replace(/'/g, "&#039;");
    }

    // CSV клетка; предпазва от формули в Excel (=, +, -, @).
    function csvCell(value) {
        let s = String(value ?? "");
        if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
        return `"${s.replace(/"/g, '""')}"`;
    }

    // Превръща грешка от Supabase в безопасно съобщение за потребителя.
    function friendlyError(error, fallback) {
        if (error && error.code === "CS001" && error.message) return error.message;
        const msg = String((error && error.message) || "");
        if (/failed to fetch|networkerror|load failed|network request failed/i.test(msg)) {
            return "Няма връзка със сървъра.";
        }
        if (error && (error.code === "42501" || /row-level security|permission denied/i.test(msg))) {
            return "Нямате право да извършите тази операция.";
        }
        return fallback || "Възникна грешка. Моля, опитайте отново.";
    }


    /* ------------------------------------------------------------------
     * ЧАСОВЕ – единственият източник на истина.
     * 13 интервала. I смяна = 7 позиции (7:30 - 13:15), II смяна = 7 позиции (12:35 - 18:30).
     * 12:35 - 13:15 е етикет на I смяна/7-ми час И на II смяна/1-ви час – две НЕЗАВИСИМИ клетки.
     * В базата: shift 1..2, hour 1..7; слотът е (ден, смяна, час).
     * ------------------------------------------------------------------ */
    const TIME_SLOTS = [
        "7:30 - 8:10", "8:20 - 9:00", "9:10 - 9:50", "10:10 - 10:50", "11:00 - 11:40",
        "11:50 - 12:30", "12:35 - 13:15", "13:30 - 14:10", "14:20 - 15:00",
        "15:10 - 15:50", "16:10 - 16:50", "17:00 - 17:40", "17:50 - 18:30"
    ];
    const POSITIONS_PER_SHIFT = 7;
    const POSITIONS = [1, 2, 3, 4, 5, 6, 7];

    /* ------------------------------------------------------------------
     * v3.0: ГРАФИКЪТ Е КОНФИГУРИРУЕМ ПО УЧИЛИЩЕ.
     * Интервалите се пазят по (смяна на консултацията, позиция) – точно тези стойности са в
     * consultations.shift/hour. Затова правилото „избрана I смяна -> 12:35–18:30, избрана II ->
     * 7:30–13:15“ е СЪДЪРЖАНИЕ на графика (по подразбиране), а не специален случай в кода:
     *   смяна 1, позиции 1..7 = TIME_SLOTS[6..12];  смяна 2, позиции 1..7 = TIME_SLOTS[0..6].
     * Режими: "two_shifts" (по подразбиране, 7+7) и "one_shift" (смяна 1, N позиции).
     * Ключът за конфликти остава (ден, смяна, час). Графикът се зарежда от сървъра (setSchedule);
     * докато не е зареден, важи подразбиращият се (поведение като до v2.9).
     * ------------------------------------------------------------------ */
    const pad2 = n => String(n).padStart(2, "0");
    // "7:30" | "07:30" | "07:30:00" -> "07:30"; "" ако е невалидно
    const toHHMM = v => {
        const m = /^(\d{1,2}):(\d{2})(?::\d{2})?$/.exec(String(v == null ? "" : v).trim());
        if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return "";
        return pad2(m[1]) + ":" + m[2];
    };
    const timeToMinutes = v => { const t = toHHMM(v); return t ? Number(t.slice(0, 2)) * 60 + Number(t.slice(3)) : NaN; };
    // "07:30","08:10" -> "7:30 - 8:10" (същият вид като TIME_SLOTS: CSV/печат/тестове)
    const intervalLabel = (start, end) => `${Number(start.slice(0, 2))}:${start.slice(3)} - ${Number(end.slice(0, 2))}:${end.slice(3)}`;

    function buildDefaultSchedule() {
        const parse = label => label.split(" - ").map(toHHMM);
        const intervals = [];
        for (let p = 1; p <= POSITIONS_PER_SHIFT; p++) {
            const [start, end] = parse(TIME_SLOTS[p + 5]);          // смяна 1 -> 12:35 ... 18:30
            intervals.push({ shift: 1, position: p, start, end });
        }
        for (let p = 1; p <= POSITIONS_PER_SHIFT; p++) {
            const [start, end] = parse(TIME_SLOTS[p - 1]);          // смяна 2 -> 7:30 ... 13:15
            intervals.push({ shift: 2, position: p, start, end });
        }
        return { mode: "two_shifts", intervals };
    }

    let activeSchedule = null;
    let slotIndex = new Map();

    // Приема { mode, intervals:[{shift,position,start,end,used?}] } (както го връща get_school_schedule).
    // Невалиден/празен вход -> подразбиращият се график.
    function setSchedule(input) {
        const src = input && Array.isArray(input.intervals) && input.intervals.length ? input : buildDefaultSchedule();
        const intervals = src.intervals
            .map(i => ({ shift: Number(i.shift), position: Number(i.position), start: toHHMM(i.start), end: toHHMM(i.end),
                         used: i.used == null ? null : Number(i.used) }))
            .filter(i => (i.shift === 1 || i.shift === 2) && Number.isInteger(i.position) && i.position >= 1 && i.start && i.end)
            .sort((a, b) => a.shift - b.shift || a.position - b.position);
        const valid = intervals.length ? intervals : buildDefaultSchedule().intervals;
        activeSchedule = { mode: src.mode === "one_shift" ? "one_shift" : "two_shifts", intervals: valid };
        slotIndex = new Map(valid.map(i => [i.shift + ":" + i.position, i]));
        return activeSchedule;
    }
    setSchedule(null);

    const getSchedule = () => activeSchedule;
    const scheduleMode = () => activeSchedule.mode;
    const activeShifts = () => [...new Set(activeSchedule.intervals.map(i => i.shift))].sort((a, b) => a - b);
    const positionsOf = shift => activeSchedule.intervals.filter(i => i.shift === Number(shift)).map(i => i.position);

    const isValidPosition = (shift, hour) => slotIndex.has(Number(shift) + ":" + Number(hour));

    // САМО за показване: интервалът на позиция (смяна, час); "" ако позицията не съществува
    // (напр. стари записи с час 8). Това НЕ е идентичност на слот: слотът е (ден, смяна, час).
    const positionLabel = (shift, hour) => {
        const i = slotIndex.get(Number(shift) + ":" + Number(hour));
        return i ? intervalLabel(i.start, i.end) : "";
    };

    // „I“ / „II“; при една смяна – „Единна“ (напр. „Единна смяна“)
    const shiftText = shift => scheduleMode() === "one_shift" ? "Единна" : (Number(shift) === 1 ? "I" : "II");

    // САМО за екранно показване: "7:30 - 8:10" -> "07:30–08:10". Не променя TIME_SLOTS, CSV и печата.
    const formatTimeRange = label => String(label || "").replace(/(\d{1,2}):(\d{2})/g, (m, h, mi) => h.padStart(2, "0") + ":" + mi).replace(/\s*-\s*/, "–");

    // Диапазонът на консултациите за избраната смяна (начало на първата до край на последната позиция).
    const shiftRangeLabel = shift => {
        const ps = positionsOf(shift);
        if (!ps.length) return "";
        const a = positionLabel(shift, ps[0]), b = positionLabel(shift, ps[ps.length - 1]);
        return a && b ? formatTimeRange(a.split(" - ")[0] + " - " + b.split(" - ")[1]) : "";
    };

    // UX проверка на редактор на интервали (сървърът проверява същото в admin_save_interval).
    // prevEnd – край на предишната позиция (или ""), nextStart – начало на следващата (или "").
    function validateIntervalInput({ start, end, prevEnd, nextStart }) {
        const errors = [], s = toHHMM(start), e = toHHMM(end);
        if (!s) errors.push("Въведете валидно начало (ЧЧ:ММ).");
        if (!e) errors.push("Въведете валиден край (ЧЧ:ММ).");
        if (s && e && timeToMinutes(s) >= timeToMinutes(e)) errors.push("Началото трябва да е преди края.");
        if (s && prevEnd && toHHMM(prevEnd) && timeToMinutes(s) < timeToMinutes(prevEnd)) errors.push("Интервалът се припокрива с предишния.");
        if (e && nextStart && toHHMM(nextStart) && timeToMinutes(e) > timeToMinutes(nextStart)) errors.push("Интервалът се припокрива със следващия.");
        return { ok: errors.length === 0, errors, start: s, end: e };
    }

    const SCHEDULE_MODES = { two_shifts: "Две смени", one_shift: "Една смяна" };
    const scheduleModeLabel = m => SCHEDULE_MODES[m] || "—";

    /* ------------------------------------------------------------------
     * v2.9: регистрация, пароли, настройки на училището, заглавна лента.
     * Всичко тук е само UX проверка – реалната защита е в базата/Auth
     * (trigger за домейна, RPC за настройки, RLS).
     * ------------------------------------------------------------------ */
    // v3.0: разрешените домейни са по училище и се пазят в базата (school_email_domains). Клиентът не ги знае
    // (преди вход няма достъп) – тук се проверява само формата; домейнът се налага от trigger върху auth.users.

    const normalizeEmail = v => String(v == null ? "" : v).trim().toLowerCase();

    const isValidEmailShape = v => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(normalizeEmail(v));
    const isAllowedEmail = v => isValidEmailShape(v);        // само форма; домейнът – на сървъра

    // Домейни (администрация на училища)
    const DOMAIN_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;
    const normalizeDomain = v => String(v == null ? "" : v).trim().toLowerCase().replace(/^@+/, "").replace(/\.+$/, "");
    const isValidDomain = d => d.length <= 253 && DOMAIN_RE.test(d);
    function validateDomainInput(v) {
        const domain = normalizeDomain(v);
        if (!domain) return { ok: false, error: "Въведете домейн (напр. school.example.bg).", domain };
        if (!isValidDomain(domain)) return { ok: false, error: "Невалиден домейн. Само латински букви, цифри, тире и точки (напр. school.example.bg).", domain };
        return { ok: true, error: "", domain };
    }
    // Покана / имейл на учител
    const validateInviteEmail = v => {
        const e = normalizeEmail(v);
        return isValidEmailShape(e) && e.length <= 254 ? { ok: true, email: e, error: "" } : { ok: false, email: e, error: "Въведете валиден имейл адрес." };
    };
    function validateSchoolName(v) {
        const n = String(v || "").trim();
        if (!n) return { ok: false, name: n, error: "Въведете име на училището." };
        if (n.length > 150) return { ok: false, name: n, error: "Името на училището е твърде дълго (до 150 символа)." };
        return { ok: true, name: n, error: "" };
    }
    const SCHOOL_STATUS = { active: "Активно", inactive: "Неактивно" };
    const schoolStatusLabel = s => SCHOOL_STATUS[s] || "—";

    // Списък със съобщения (на български) за липсващите изисквания; празен = паролата е приемлива.
    function passwordProblems(pw) {
        const p = String(pw == null ? "" : pw), out = [];
        if (p.length < 8) out.push("Паролата трябва да е поне 8 символа.");
        if (!/\p{Lu}/u.test(p)) out.push("Паролата трябва да съдържа поне една главна буква.");
        if (!/\p{Ll}/u.test(p)) out.push("Паролата трябва да съдържа поне една малка буква.");
        if (!/\d/.test(p)) out.push("Паролата трябва да съдържа поне една цифра.");
        return out;
    }

    // { ok, errors: [..], email } – email е нормализиран (trim + lowercase)
    function validateRegistration({ name, email, password, password2 }) {
        const errors = [], n = String(name || "").trim(), e = normalizeEmail(email);
        if (!n) errors.push("Моля, въведете име и фамилия.");
        else if (n.length < 3 || n.length > 100) errors.push("Името трябва да е между 3 и 100 символа.");
        if (!e) errors.push("Моля, въведете имейл.");
        else if (!isValidEmailShape(e)) errors.push("Въведете валиден имейл адрес.");
        if (!password) errors.push("Моля, въведете парола.");
        else errors.push(...passwordProblems(password));
        if (!password2) errors.push("Моля, повторете паролата.");
        else if (password && password !== password2) errors.push("Паролите не съвпадат.");
        return { ok: errors.length === 0, errors, email: e, name: n };
    }

    function validatePasswordChange({ current, next, repeat }) {
        const errors = [];
        if (!current) errors.push("Моля, въведете текущата парола.");
        if (!next) errors.push("Моля, въведете нова парола.");
        else {
            errors.push(...passwordProblems(next));
            if (current && next === current) errors.push("Новата парола трябва да е различна от текущата.");
        }
        if (!repeat) errors.push("Моля, повторете новата парола.");
        else if (next && next !== repeat) errors.push("Новата парола и повторението не съвпадат.");
        return { ok: errors.length === 0, errors };
    }

    const TERMS = { I: "I срок", II: "II срок" };
    const termLabel = t => TERMS[String(t || "").toUpperCase()] || "";
    const roleLabel = r => r === "super_admin" ? "Супер администратор" : r === "admin" ? "Администратор" : "Учител";
    const USER_STATUS = { active: "Активен", pending: "Непотвърден имейл", blocked: "Блокиран" };
    const userStatusLabel = s => USER_STATUS[s] || "—";

    // Втори ред на лявата част на заглавната лента: "I срок · 2026/2027" (празно, ако няма настройки)
    function termLine(settings) {
        if (!settings) return "";
        return [termLabel(settings.current_term), settings.academic_year].filter(Boolean).join(" · ");
    }
    // Дясна част: "Мария Петрова · Администратор"
    const userLine = (name, role) => [String(name || "").trim(), name ? roleLabel(role) : ""].filter(Boolean).join(" · ");

    function validateSettings({ school_name, academic_year, current_term }) {
        const errors = [], n = String(school_name || "").trim(), y = String(academic_year || "").trim();
        if (!n) errors.push("Въведете име на училището.");
        else if (n.length > 150) errors.push("Името на училището е твърде дълго (до 150 символа).");
        const m = y.match(/^(\d{4})\/(\d{4})$/);
        if (!m || Number(m[2]) !== Number(m[1]) + 1) errors.push("Учебната година трябва да е във формат 2026/2027 (последователни години).");
        if (!TERMS[String(current_term || "").toUpperCase()]) errors.push("Изберете срок (I или II).");
        return { ok: errors.length === 0, errors, value: { school_name: n, academic_year: y, current_term: String(current_term || "").toUpperCase() } };
    }

    /* ------------------------------------------------------------------
     * ЕТАПИ – определят се само от номера на класа (без ново поле в базата)
     * ------------------------------------------------------------------ */
    const STAGES = {
        gymnasium:    { label: "Гимназиален етап",    short: "Гимназиален",    file: "gimnazialen-etap",    minGrade: 8, maxGrade: 12 },
        progymnasium: { label: "Прогимназиален етап", short: "Прогимназиален", file: "progimnazialen-etap", minGrade: 5, maxGrade: 7 }
    };
    const STAGE_ORDER = ["gymnasium", "progymnasium"];
    const DEFAULT_STAGE = "gymnasium";

    const gradeOfClass = name => { const m = /^\s*(\d{1,2})/.exec(String(name || "")); return m ? Number(m[1]) : NaN; };

    // "gymnasium" | "progymnasium" | null (клас извън 5-12 няма етап)
    function stageOfClass(name) {
        const g = gradeOfClass(name);
        return STAGE_ORDER.find(k => g >= STAGES[k].minGrade && g <= STAGES[k].maxGrade) || null;
    }

    const classesOfStage = (names, stage) =>
        names.filter(n => stageOfClass(n) === stage).sort(compareClassNames);

    // Консултациите за етапа; classes/className са ограничени до класовете на етапа.
    // (Консултация с класове от двата етапа се вижда и в двата, но само със своите класове.)
    function scopeRecords(records, stage) {
        const out = [];
        records.forEach(r => {
            const classes = normalizeClasses(r).filter(c => stageOfClass(c) === stage);
            if (classes.length) out.push({ ...r, classes, className: classes[0] });
        });
        return out;
    }

    /* ------------------------------------------------------------------
     * КЛАСОВЕ: валидация и име (5А ... 12В)
     * ------------------------------------------------------------------ */
    // Латински букви, които изглеждат като кирилица -> кирилица (за да няма "невидими" дубликати).
    const LATIN_LOOKALIKES = { "A": "\u0410", "B": "\u0412", "E": "\u0415", "K": "\u041A", "M": "\u041C",
                               "H": "\u041D", "O": "\u041E", "P": "\u0420", "C": "\u0421", "T": "\u0422",
                               "X": "\u0425" };

    function normalizeParallel(letter) {
        return String(letter || "").trim().toUpperCase().split("").map(ch => LATIN_LOOKALIKES[ch] || ch).join("");
    }

    function buildClassName(grade, letter) {
        const g = Number(grade);
        if (String(grade).trim() === "" || !Number.isInteger(g) || g < 5 || g > 12) {
            return { ok: false, error: "Номерът на класа трябва да е цяло число от 5 до 12." };
        }
        const l = normalizeParallel(letter);
        if (!/^[\u0410-\u042F]$/.test(l)) {
            return { ok: false, error: "Паралелката трябва да е една буква (А–Я)." };
        }
        return { ok: true, name: `${g}${l}`, grade: g, letter: l };
    }


    /* ------------------------------------------------------------------
     * СМЕНИ: при смяна на етапа смяната се обръща (I <-> II).
     * Реалното разпределение: когато единият етап е на I смяна, другият е на II.
     * ------------------------------------------------------------------ */
    const getOppositeShift = shift => activeShifts().length < 2 ? (Number(shift) || 1) : (Number(shift) === 1 ? 2 : 1);

    // Етапи на консултация според класовете ѝ: "Прогимназиален / Гимназиален"
    function stageNamesOfRecord(record) {
        const keys = new Set(normalizeClasses(record).map(stageOfClass).filter(Boolean));
        return ["progymnasium", "gymnasium"].filter(k => keys.has(k)).map(k => STAGES[k].short).join(" / ");
    }

    // Подредба по ден, смяна, час (после предмет)
    function compareRecordsByTime(a, b) {
        return (dayToIndex(a.day) - dayToIndex(b.day)) ||
               (Number(a.shift) - Number(b.shift)) ||
               (Number(a.hour) - Number(b.hour)) ||
               String(a.subject).localeCompare(String(b.subject), "bg");
    }

    /* ------------------------------------------------------------------
     * ПРОВЕРКА ЗА КОНФЛИКТ ПРИ ПОПЪЛВАНЕ (UX). Огледало на правилата на сървъра
     * (save_consultation) върху вече заредените данни. Сървърът остава последната защита.
     * Слотът е (ден, смяна, час): I смяна/7 и II смяна/1 са независими.
     * ------------------------------------------------------------------ */
    const sameCell = (r, p) => r.day === p.day && Number(r.shift) === Number(p.shift) && Number(r.hour) === Number(p.hour);
    const notSelf = (r, p) => !p.excludeId || String(r.id) !== String(p.excludeId);
    const normLocation = v => String(v || "").trim().toLocaleLowerCase("bg-BG");

    const isGroupSubjectIn = (subject, groupSubjects) =>
        !!normalizeSubject(subject) && (groupSubjects || []).some(g => normalizeSubject(g) === normalizeSubject(subject));

    // null или { type: "occupied" | "groups_full" | "same_location", record }
    function findClassConflict(records, p) {
        const cell = records.filter(r => notSelf(r, p) && sameCell(r, p) && normalizeClasses(r).includes(p.className));
        if (!cell.length) return null;
        const group = isGroupSubjectIn(p.subject, p.groupSubjects);
        const sameSubject = cell.every(r => normalizeSubject(r.subject) === normalizeSubject(p.subject));
        if (!group || !sameSubject) return { type: "occupied", record: cell[0] };
        if (cell.length >= 2) return { type: "groups_full", record: cell[0] };
        const loc = normLocation(p.location);
        const clash = loc ? cell.find(r => normLocation(r.location) === loc) : null;
        return clash ? { type: "same_location", record: clash } : null;
    }

    // Същият учител вече има консултация в същата клетка (ден + смяна + час)?
    function findTeacherConflict(records, p) {
        return records.find(r => notSelf(r, p) && sameCell(r, p) && r.teacherId === p.teacherId) || null;
    }

    function evaluateSelection(records, p) {
        const selected = p.classes || [];
        const conflicts = {}, free = [], blocked = [];
        selected.forEach(c => {
            const x = findClassConflict(records, { ...p, className: c });
            if (x) { conflicts[c] = x; blocked.push(c); } else free.push(c);
        });
        const teacherConflict = p.teacherId ? findTeacherConflict(records, p) : null;
        const needsLocation = isGroupSubjectIn(p.subject, p.groupSubjects) && !String(p.location || "").trim();
        return {
            free, blocked, conflicts, teacherConflict, needsLocation,
            noClasses: selected.length === 0,
            allBlocked: selected.length > 0 && free.length === 0,
            canSave: free.length > 0 && !teacherConflict && !needsLocation
        };
    }

    // Съобщения под списъка с класове: [{ level: "ok"|"warn"|"error", text }]
    function summarizeSelection(ev) {
        const out = [];
        if (ev.noClasses) out.push({ level: "error", text: "Изберете поне един клас." });
        if (ev.teacherConflict) out.push({ level: "error", text: "⚠️ Вече има ваша консултация в този ден, смяна и час. Изберете друг час." });
        if (ev.allBlocked) {
            out.push({ level: "error", text: "⚠️ Всички избрани класове имат конфликт в този час. Изберете друг час или премахнете конфликтните класове." });
        } else if (ev.blocked.length) {
            const n = ev.blocked.length;
            out.push({ level: "warn", text: `⚠ ${n} ${n === 1 ? "избран клас има" : "избрани класа имат"} конфликт. Можете да продължите с останалите свободни класове.` });
        }
        if (ev.needsLocation) out.push({ level: "error", text: "⚠ При предмет с паралелни групи трябва да бъде посочено място." });
        if (!out.length) out.push({ level: "ok", text: "✓ Няма конфликти." });
        return out;
    }

    // Конкретно описание на конфликта: заглавие + редове "Предмет / Ден / Смяна / Час / Учител"
    function describeClassConflict(className, conflict) {
        const r = conflict.record;
        const title = conflict.type === "groups_full" ? `⚠️ ${className}: вече има две паралелни групи в този час.`
            : conflict.type === "same_location" ? `⚠️ ${className}: местото „${r.location}“ вече се ползва от паралелна група.`
            : `⚠️ ${className} вече има консултация.`;
        const details = [["Предмет", r.subject], ["Ден", r.day], ["Смяна", shiftText(r.shift)],
                         ["Час", positionLabel(r.shift, r.hour) || String(r.hour)], ["Учител", r.teacher]];
        if (r.location) details.push(["Място", r.location]);
        return { title, details };
    }

    // Маркер до всеки клас: "✓" (избран и свободен), "⚠ Има конфликт", или "".
    function classMarkers(records, p, classNames) {
        const selected = new Set(p.classes || []);
        const out = {};
        classNames.forEach(c => {
            const x = findClassConflict(records, { ...p, className: c });
            out[c] = x ? "⚠ Има конфликт" : (selected.has(c) ? "✓" : "");
        });
        return out;
    }

    // Групира в логически клетки: "клас|смяна|ден|час" (за статистиката).
    function countOccupiedCells(records) {
        const cells = new Set();
        records.forEach(r => normalizeClasses(r).forEach(c => cells.add(`${c}|${r.shift}|${r.hour}|${r.day}`)));
        return cells.size;
    }

    const api = { DAY_NAMES, dayToIndex, indexToDay, normalizeSubject, normalizeClasses,
                  compareClassNames, escapeHtml, csvCell, friendlyError, countOccupiedCells,
                  TIME_SLOTS, POSITIONS, POSITIONS_PER_SHIFT, isValidPosition,
                  positionLabel, shiftText, formatTimeRange, shiftRangeLabel,
                  setSchedule, getSchedule, scheduleMode, activeShifts, positionsOf, buildDefaultSchedule, toHHMM, timeToMinutes,
                  intervalLabel, validateIntervalInput, scheduleModeLabel, SCHEDULE_MODES,
                  normalizeDomain, isValidDomain, validateDomainInput, validateInviteEmail, validateSchoolName, schoolStatusLabel,
                  normalizeEmail, isValidEmailShape, isAllowedEmail, passwordProblems, validateRegistration,
                  validatePasswordChange, termLabel, roleLabel, userStatusLabel, termLine, userLine, validateSettings, normalizeParallel, buildClassName,
                  STAGES, STAGE_ORDER, DEFAULT_STAGE, gradeOfClass, stageOfClass, classesOfStage, scopeRecords,
                  getOppositeShift, stageNamesOfRecord, compareRecordsByTime, isGroupSubjectIn, findClassConflict,
                  findTeacherConflict, evaluateSelection, summarizeSelection, describeClassConflict, classMarkers };
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    else Object.assign(root, api);
})(typeof window !== "undefined" ? window : globalThis);
