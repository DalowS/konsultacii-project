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

    // Групира в логически клетки: "клас|смяна|ден|час" (за статистиката).
    function countOccupiedCells(records) {
        const cells = new Set();
        records.forEach(r => normalizeClasses(r).forEach(c => cells.add(`${c}|${r.shift}|${r.day}|${r.hour}`)));
        return cells.size;
    }

    const api = { DAY_NAMES, dayToIndex, indexToDay, normalizeSubject, normalizeClasses,
                  compareClassNames, escapeHtml, csvCell, friendlyError, countOccupiedCells };
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    else Object.assign(root, api);
})(typeof window !== "undefined" ? window : globalThis);
