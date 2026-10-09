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

    const isValidPosition = (shift, hour) =>
        (Number(shift) === 1 || Number(shift) === 2) &&
        Number.isInteger(Number(hour)) && Number(hour) >= 1 && Number(hour) <= POSITIONS_PER_SHIFT;

    // САМО за показване: индекс в TIME_SLOTS за позиция (смяна, час). Не е идентичност на слот –
    // слотът в графика и при конфликтите е (ден, смяна, час); I смяна/7 и II смяна/1 са независими
    // клетки, които просто имат еднакъв етикет 12:35 - 13:15.
    const labelIndex = (shift, hour) => (Number(shift) === 1 ? Number(hour) : Number(hour) + 6) - 1;

    // Интервал за позиция; "" ако позицията е невалидна (напр. стари записи с час 8).
    const positionLabel = (shift, hour) => isValidPosition(shift, hour) ? (TIME_SLOTS[labelIndex(shift, hour)] || "") : "";

    const shiftText = shift => Number(shift) === 1 ? "I" : "II";

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
    const getOppositeShift = shift => Number(shift) === 1 ? 2 : 1;

    // regularShifts идва от единствената училищна настройка в базата данни.
    // Консултациите са в смяната срещу редовната учебна смяна.
    function consultationShiftForStage(stage, regularShifts) {
        const regular = Number(regularShifts && regularShifts[stage]);
        return (stage === "gymnasium" || stage === "progymnasium") && (regular === 1 || regular === 2)
            ? getOppositeShift(regular) : null;
    }

    function evaluateStageShift(classes, shift, regularShifts) {
        const names = [...new Set((classes || []).map(v => String(v).trim()).filter(Boolean))];
        if (!names.length) return { ok: false, reason: "no_classes", stage: null, expectedShift: null };
        const stages = [...new Set(names.map(stageOfClass))];
        if (stages.includes(null)) return { ok: false, reason: "unknown_stage", stage: null, expectedShift: null };
        if (stages.length !== 1) return { ok: false, reason: "mixed_stages", stage: null, expectedShift: null };
        const stage = stages[0];
        const expectedShift = consultationShiftForStage(stage, regularShifts);
        if (!expectedShift) return { ok: false, reason: "missing_config", stage, expectedShift: null };
        return { ok: Number(shift) === expectedShift, reason: Number(shift) === expectedShift ? "ok" : "wrong_shift", stage, expectedShift };
    }

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
                  positionLabel, shiftText, normalizeParallel, buildClassName,
                  STAGES, STAGE_ORDER, DEFAULT_STAGE, gradeOfClass, stageOfClass, classesOfStage, scopeRecords,
                  getOppositeShift, consultationShiftForStage, evaluateStageShift,
                  stageNamesOfRecord, compareRecordsByTime, isGroupSubjectIn, findClassConflict,
                  findTeacherConflict, evaluateSelection, summarizeSelection, describeClassConflict, classMarkers };
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    else Object.assign(root, api);
})(typeof window !== "undefined" ? window : globalThis);
