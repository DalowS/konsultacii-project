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
     * 13 физически слота. I смяна = слотове 1..7, II смяна = слотове 7..13.
     * Слот 7 (12:35 - 13:15) е ОБЩ за двете смени.
     * В базата (shift, hour) остава: shift 1..2, hour 1..7 (позиция в смяната).
     *   slot = shift 1 ? hour : hour + 6
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

    // Физически слот (1..13). Ползва се САМО за реален времеви конфликт (сървърът прави същото
    // с slot_of()). Клетките в графика са отделни: I смяна/7 и II смяна/1 НЕ се оглеждат.
    const slotOf = (shift, hour) => Number(shift) === 1 ? Number(hour) : Number(hour) + 6;
    const slotLabel = slot => TIME_SLOTS[slot - 1] || "";

    // Интервал за позиция; "" ако позицията е невалидна (напр. стари записи с час 8).
    const positionLabel = (shift, hour) => isValidPosition(shift, hour) ? slotLabel(slotOf(shift, hour)) : "";

    const shiftText = shift => Number(shift) === 1 ? "I" : "II";

    /* ------------------------------------------------------------------
     * ЕТАПИ – определят се само от номера на класа (без ново поле в базата)
     * ------------------------------------------------------------------ */
    const STAGES = {
        gymnasium:    { label: "Гимназиален етап",    file: "gimnazialen-etap",    minGrade: 8, maxGrade: 12 },
        progymnasium: { label: "Прогимназиален етап", file: "progimnazialen-etap", minGrade: 5, maxGrade: 7 }
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

    // Групира в логически клетки: "клас|смяна|ден|час" (за статистиката).
    function countOccupiedCells(records) {
        const cells = new Set();
        records.forEach(r => normalizeClasses(r).forEach(c => cells.add(`${c}|${r.shift}|${r.hour}|${r.day}`)));
        return cells.size;
    }

    const api = { DAY_NAMES, dayToIndex, indexToDay, normalizeSubject, normalizeClasses,
                  compareClassNames, escapeHtml, csvCell, friendlyError, countOccupiedCells,
                  TIME_SLOTS, POSITIONS, POSITIONS_PER_SHIFT, isValidPosition, slotOf, slotLabel,
                  positionLabel, shiftText, normalizeParallel, buildClassName,
                  STAGES, STAGE_ORDER, DEFAULT_STAGE, gradeOfClass, stageOfClass, classesOfStage, scopeRecords };
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    else Object.assign(root, api);
})(typeof window !== "undefined" ? window : globalThis);
