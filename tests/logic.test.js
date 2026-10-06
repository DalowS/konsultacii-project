const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const vm = require("vm");
const L = require("../js/logic.js");

test("day mapping", () => {
    assert.equal(L.dayToIndex("Понеделник"), 1);
    assert.equal(L.dayToIndex("Петък"), 5);
    assert.equal(L.dayToIndex("Събота"), 0);
    assert.equal(L.indexToDay(3), "Сряда");
    assert.equal(L.indexToDay(9), "");
});

test("normalizeClasses: string and array, dedupe", () => {
    assert.deepEqual(L.normalizeClasses({ classes: "8А, 8Б,8А" }), ["8А", "8Б"]);
    assert.deepEqual(L.normalizeClasses({ classes: ["9А", " 9А ", "9Б"] }), ["9А", "9Б"]);
    assert.deepEqual(L.normalizeClasses({ className: "10В" }), ["10В"]);
});

test("class ordering is numeric then letter", () => {
    const sorted = ["10А", "8Б", "9А", "8А", "12В", "11Б"].sort(L.compareClassNames);
    assert.deepEqual(sorted, ["8А", "8Б", "9А", "10А", "11Б", "12В"]);
});

test("escapeHtml and csvCell (XSS / formula injection)", () => {
    assert.equal(L.escapeHtml(`<img src=x onerror="a('b')">`),
        "&lt;img src=x onerror=&quot;a(&#039;b&#039;)&quot;&gt;");
    assert.equal(L.csvCell('a"b'), '"a""b"');
    assert.equal(L.csvCell("=SUM(A1)"), `"'=SUM(A1)"`);
});

test("occupied cells count logical cells, not records", () => {
    const recs = [
        { classes: ["8А", "8Б", "8В"], shift: 1, day: "Понеделник", hour: 1 },
        { classes: ["8А"], shift: 1, day: "Понеделник", hour: 1 },   // паралелна група – същата клетка
        { classes: ["8А"], shift: 1, day: "Вторник", hour: 1 }
    ];
    assert.equal(L.countOccupiedCells(recs), 4);
});

test("friendlyError never leaks internals", () => {
    assert.equal(L.friendlyError({ code: "CS001", message: "Клас 8А вече има консултация." }, "x"),
        "Клас 8А вече има консултация.");
    assert.equal(L.friendlyError({ message: "TypeError: Failed to fetch" }, "x"), "Няма връзка със сървъра.");
    assert.equal(L.friendlyError({ code: "42501", message: "new row violates row-level security" }, "x"),
        "Нямате право да извършите тази операция.");
    assert.equal(L.friendlyError({ code: "XX000", message: "password=secret host=db" }, "Общо"), "Общо");
});

// ---- storage слой с фалшив Supabase клиент ----
function loadStorage(fakeRows) {
    const tables = {
        classes: [{ id: 2, name: "8Б" }, { id: 1, name: "8А" }, { id: 3, name: "10А" }],
        group_subjects: [{ id: 1, subject: "ИТ", enabled: true }],
        teachers: [{ id: "t1", name: "Иван", role: "teacher" }],
        consultations: fakeRows
    };
    const calls = [];
    const builder = table => {
        const b = { select: () => b, order: () => b, range: () => b,
            then: res => res({ data: table === "consultations" ? tables[table] : tables[table], error: null }) };
        return b;
    };
    const sb = { from: builder, rpc: (name, args) => { calls.push([name, args]); return Promise.resolve({ data: 1, error: null }); } };
    const ctx = { sb, ...L, console };
    vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(__dirname + "/../js/storage.js", "utf8") + "\nthis.storage = storage;", ctx);
    return { storage: ctx.storage, calls };
}

test("storage.refresh normalizes joined rows", async () => {
    const { storage } = loadStorage([{
        id: 7, teacher_id: "t1", day: 2, shift: 1, hour: 3, subject: "ИТ", location: null,
        teachers: { name: "Иван" },
        consultation_classes: [{ classes: { name: "10А" } }, { classes: { name: "8Б" } }, { classes: { name: "8А" } }]
    }]);
    await storage.refresh();
    const r = storage.getAll()[0];
    assert.equal(r.id, "7");
    assert.equal(r.day, "Вторник");
    assert.deepEqual(r.classes, ["8А", "8Б", "10А"]);
    assert.equal(r.teacher, "Иван");
    assert.deepEqual(storage.getClassNames(), ["8А", "8Б", "10А"]);
});

test("storage.add sends normalized RPC payload", async () => {
    const { storage, calls } = loadStorage([]);
    await storage.add({ day: "Сряда", shift: 2, hour: 4, subject: "Математика", location: "", classes: ["8А", "8А", "9Б"] });
    assert.equal(calls[0][0], "save_consultation");
    assert.deepEqual(JSON.parse(JSON.stringify(calls[0][1])), {
        p_id: null, p_day: 3, p_shift: 2, p_hour: 4, p_subject: "Математика", p_location: null, p_classes: ["8А", "9Б"]
    });
});

/* ===================== v2.1: часове, класове, учители ===================== */

test("13 реални интервала, 7 позиции на смяна", () => {
    assert.deepEqual(L.TIME_SLOTS, [
        "7:30 - 8:10", "8:20 - 9:00", "9:10 - 9:50", "10:10 - 10:50", "11:00 - 11:40", "11:50 - 12:30",
        "12:35 - 13:15", "13:30 - 14:10", "14:20 - 15:00", "15:10 - 15:50", "16:10 - 16:50",
        "17:00 - 17:40", "17:50 - 18:30"]);
    assert.deepEqual(L.POSITIONS, [1, 2, 3, 4, 5, 6, 7]);
    const shift1 = L.POSITIONS.map(h => L.positionLabel(1, h));
    const shift2 = L.POSITIONS.map(h => L.positionLabel(2, h));
    assert.equal(shift1[0], "7:30 - 8:10");
    assert.equal(shift1[6], "12:35 - 13:15");
    assert.equal(shift2[0], "12:35 - 13:15");
    assert.equal(shift2[6], "17:50 - 18:30");
});




test("невалидни (стари) позиции – час 8 няма интервал", () => {
    assert.equal(L.isValidPosition(1, 8), false);
    assert.equal(L.isValidPosition(2, 0), false);
    assert.equal(L.isValidPosition(3, 1), false);
    assert.equal(L.positionLabel(1, 8), "");
    assert.equal(L.positionLabel(2, 8), "");
});



test("подредба на класовете 5А ... 12В", () => {
    const names = [];
    for (let g = 5; g <= 12; g++) for (const l of ["А", "Б", "В"]) names.push(`${g}${l}`);
    const shuffled = [...names].reverse();
    assert.deepEqual(shuffled.sort(L.compareClassNames), names);
});

test("storage: класове и учители", async () => {
    const { storage, calls } = loadStorage([]);
    await storage.addClass(5, "А");
    await storage.deleteTeacher("00000000-0000-0000-0000-000000000001");
    assert.deepEqual(JSON.parse(JSON.stringify(calls[0])), ["admin_add_class", { p_grade: 5, p_letter: "А" }]);
    assert.deepEqual(JSON.parse(JSON.stringify(calls[1])),
        ["admin_delete_teacher", { p_teacher: "00000000-0000-0000-0000-000000000001" }]);
    await storage.refresh();
    assert.equal(storage.getClasses().length, 3);
});


/* ===================== v2.2: отделни клетки + етапи ===================== */

test("12:35 - 13:15 са две отделни позиции със същия интервал", () => {
    assert.equal(L.positionLabel(1, 7), "12:35 - 13:15");
    assert.equal(L.positionLabel(2, 1), "12:35 - 13:15");
    // физическият слот е общ (ползва се само при проверка за конфликт на сървъра)...
    assert.equal(L.slotOf(1, 7), L.slotOf(2, 1));
    // ...но позициите (shift,hour) са различни и няма функции за канонизиране/сливане
    for (const name of ["canonicalPosition", "isSharedPosition", "sameSlot", "recordInShift", "SHARED_SLOT"]) {
        assert.equal(L[name], undefined, name);
    }
    assert.equal(L.shiftText(1), "I");
    assert.equal(L.shiftText(2), "II");
});

test("статистика: I/7 и II/1 са две отделни клетки", () => {
    const recs = [
        { classes: ["8А"], shift: 1, day: "Понеделник", hour: 7 },
        { classes: ["8А"], shift: 2, day: "Понеделник", hour: 1 },
        { classes: ["8А"], shift: 2, day: "Понеделник", hour: 2 }
    ];
    assert.equal(L.countOccupiedCells(recs), 3);
});

test("етап според номера на класа (1-4)", () => {
    assert.equal(L.stageOfClass("5А"), "progymnasium");           // 1
    assert.equal(L.stageOfClass("7В"), "progymnasium");           // 2
    assert.equal(L.stageOfClass("8А"), "gymnasium");              // 3
    assert.equal(L.stageOfClass("12В"), "gymnasium");             // 4
    assert.equal(L.stageOfClass("4А"), null);
    assert.equal(L.stageOfClass("13А"), null);
    assert.equal(L.stageOfClass("10Б"), "gymnasium");             // двуцифрен номер
});

test("нови класове попадат в правилния етап (5-6)", () => {
    const names = ["8А", "9Б", "5А"];
    assert.ok(!L.classesOfStage(names, "progymnasium").includes("6А"));
    names.push("6А", "9А");
    assert.deepEqual(L.classesOfStage(names, "progymnasium"), ["5А", "6А"]);
    assert.deepEqual(L.classesOfStage(names, "gymnasium"), ["8А", "9А", "9Б"]);
});

test("scopeRecords: само класовете на етапа; смесена консултация – и в двата, със своите класове", () => {
    const recs = [{ id: 1, classes: ["7А", "8А"] }, { id: 2, classes: ["5А"] }, { id: 3, classes: ["12В"] }];
    const gym = L.scopeRecords(recs, "gymnasium");
    const pro = L.scopeRecords(recs, "progymnasium");
    assert.deepEqual(gym.map(r => [r.id, r.classes.join()]), [[1, "8А"], [3, "12В"]]);
    assert.deepEqual(pro.map(r => [r.id, r.classes.join()]), [[1, "7А"], [2, "5А"]]);
    assert.equal(recs[0].classes.length, 2, "оригиналът не се променя");
});

test("buildClassName: 5-12, главна буква, латински двойници", () => {
    assert.deepEqual(L.buildClassName(5, "А"), { ok: true, name: "5А", grade: 5, letter: "А" });
    assert.equal(L.buildClassName(12, "в").name, "12В");
    assert.equal(L.buildClassName(6, "A").name, "6\u0410");
    assert.equal(L.buildClassName("7", "Б").name, "7Б");
    for (const [g, l] of [[0, "А"], [4, "А"], [13, "А"], [5.5, "А"], ["", "А"], ["x", "А"], [5, ""], [5, "АБ"], [5, "5"], [5, "Z"]]) {
        assert.equal(L.buildClassName(g, l).ok, false, `${g}${l}`);
    }
});

test("статични проверки на frontend-а", () => {
    const read = f => fs.readFileSync(__dirname + "/../" + f, "utf8");
    const html = read("index.html");
    const app = read("js/app.js");
    const files = ["index.html", "js/app.js", "js/storage.js", "js/auth.js", "js/supabase.js", "js/logic.js"];
    assert.ok(!html.includes("Обнови"));
    for (const f of files) {
        assert.ok(!/service_role/i.test(read(f).replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "")), `service_role в ${f}`);
    }
    // един източник за часовете: интервалът 13:30 - 14:10 се среща само в logic.js
    const holders = files.filter(f => read(f).includes("13:30 - 14:10"));
    assert.deepEqual(holders, ["js/logic.js"]);
    assert.ok(!/hourLabels/.test(app));
    // клетките не се оглеждат: app.js изобщо не ползва физически слот
    assert.ok(!/slotOf|canonicalPosition|isSharedPosition/.test(app), "app.js не трябва да ползва slot");
    const fn = app.slice(app.indexOf("function getCellRecords"), app.indexOf("function renderSchedule"));
    assert.ok(/record\.shift\) === Number\(shift\)/.test(fn) && /record\.hour\) === Number\(hour\)/.test(fn));
    // резервно презареждане + realtime са запазени
    assert.ok(/function reloadData\(/.test(app) && /setInterval\(reloadData, 30000\)/.test(app));
    for (const t of ["consultations", "consultation_classes", "group_subjects", "classes", "teachers"]) {
        assert.ok(app.includes(`"${t}"`), `realtime таблица ${t}`);
    }
    // етапите са само филтър: няма втори storage/таблица за етап
    assert.ok(!/from\("(gymnasium|progymnasium|gimnazia|progimnazia)/i.test(read("js/storage.js")));
    assert.equal((read("js/storage.js").match(/const storage = /g) || []).length, 1);
});

test("SQL v2.2: без канонизиране, конфликтите остават по slot_of", () => {
    const sql = fs.readFileSync(__dirname + "/../supabase/migrations/20261007000000_separate_shift_cells.sql", "utf8");
    const code = sql.replace(/--[^\n]*/g, "");
    assert.ok(!/p_shift\s*:=|p_hour\s*:=/.test(code), "няма канонизиране");
    assert.ok(/slot_of\(c\.shift, c\.hour\) = v_slot/.test(code), "конфликт на учител по слот");
    assert.ok(/slot_of\(o\.shift, o\.hour\) = v_slot/.test(code), "конфликт на клас по слот");
    assert.ok(/between 5 and 12/.test(code));
});
