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
function loadStorage(fakeRows, rpcData = 1) {
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
    const sb = { from: builder, rpc: (name, args) => { calls.push([name, args]); return Promise.resolve({ data: rpcData, error: null }); } };
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

test("storage loads the centralized stage regular shifts via RPC", async () => {
    const config = { gymnasium: 1, progymnasium: 2 };
    const { storage, calls } = loadStorage([], config);
    await storage.loadStageRegularShifts();
    assert.deepEqual(JSON.parse(JSON.stringify(storage._stageRegularShifts)), config);
    assert.equal(calls[0][0], "get_consultation_stage_shifts");
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


/* ===================== v2.3: независими смени, печат ===================== */

test("12:35 - 13:15 е само етикет: две независими позиции, без концепция за физически слот", () => {
    assert.equal(L.positionLabel(1, 7), "12:35 - 13:15");
    assert.equal(L.positionLabel(2, 1), "12:35 - 13:15");
    for (const name of ["slotOf", "slotLabel", "canonicalPosition", "isSharedPosition", "sameSlot", "recordInShift", "SHARED_SLOT"]) {
        assert.equal(L[name], undefined, `${name} не трябва да съществува`);
    }
    assert.ok(!/slotOf|slotLabel/.test(fs.readFileSync(__dirname + "/../js/logic.js", "utf8")));
});

test("4: всички часови интервали са непроменени (I и II смяна)", () => {
    const shift1 = ["7:30 - 8:10", "8:20 - 9:00", "9:10 - 9:50", "10:10 - 10:50", "11:00 - 11:40", "11:50 - 12:30", "12:35 - 13:15"];
    const shift2 = ["12:35 - 13:15", "13:30 - 14:10", "14:20 - 15:00", "15:10 - 15:50", "16:10 - 16:50", "17:00 - 17:40", "17:50 - 18:30"];
    assert.deepEqual(L.POSITIONS.map(h => L.positionLabel(1, h)), shift1);
    assert.deepEqual(L.POSITIONS.map(h => L.positionLabel(2, h)), shift2);
    assert.equal(L.TIME_SLOTS.length, 13);
});

test("1-3 (SQL, статична проверка): слотът е (ден, смяна, час) навсякъде", () => {
    const dir = __dirname + "/../supabase/migrations/";
    const code = fs.readFileSync(dir + "20261008000000_independent_shifts.sql", "utf8").replace(/--[^\n]*/g, "");
    // няма физически слот в нито една проверка
    const noDrop = code.replace(/drop function if exists public\.slot_of\(int, int\);/, "");
    assert.ok(!/slot_of|v_slot|physical/i.test(noDrop), "няма slot_of/v_slot");
    assert.ok(/drop function if exists public\.slot_of/.test(code), "slot_of се премахва");
    // уникален индекс: учител + ден + смяна + час
    assert.ok(/create unique index consultations_teacher_slot_uq\s+on public\.consultations \(teacher_id, day, shift, hour\)/.test(code));
    // заетост на учител: същата клетка
    assert.ok(/c\.teacher_id = p_teacher and c\.day = p_day\s+and c\.shift = p_shift and c\.hour = p_hour/.test(code));
    // клас/паралелни групи: същата клетка
    assert.ok(/o\.day = p_day and o\.shift = p_shift and o\.hour = p_hour/.test(code));
    // заключване на клетката
    assert.ok(/p_day \* 100 \+ p_shift \* 10 \+ p_hour/.test(code));
    // импорт: дубликат по ден+смяна+час
    assert.ok(/c\.shift = v_shift and c\.hour = v_hour/.test(code));
    // нормалните конфликти в рамките на една клетка са запазени (3)
    for (const msg of ["Учителят вече има друга консултация", "вече има консултация в този час", "вече има две групи"]) {
        assert.ok(code.includes(msg), msg);
    }
    // няма канонизиране (II/1 -> I/7)
    assert.ok(!/p_shift\s*:=|p_hour\s*:=/.test(code));
    // часовете 1..7 са валидни
    assert.ok(/p_hour not between 1 and 7/.test(code));
});

test("v2.6 миграцията пази независимите клетки и проверява смяната на етапа в RPC", () => {
    const dir = __dirname + "/../supabase/migrations/";
    const files = fs.readdirSync(dir).sort();
    assert.equal(files[files.length - 1], "20261009000000_stage_consultation_shifts.sql");
    const sql = fs.readFileSync(dir + files[files.length - 1], "utf8").replace(/--[^\n]*/g, "");
    assert.match(sql, /values \('gymnasium', 1\), \('progymnasium', 2\)/);
    assert.match(sql, /v_stage_count > 1/);
    assert.match(sql, /v_expected_shift := 3 - v_regular_shift/);
    assert.match(sql, /if p_shift <> v_expected_shift then/);
    assert.match(sql, /o\.shift = p_shift and o\.hour = p_hour/);
    assert.doesNotMatch(sql, /slot_of|v_slot|physical/i);
});

test("v2.6 има директни RPC проверки за двете настройки, отказите и независимите клетки", () => {
    const sql = fs.readFileSync(__dirname + "/../supabase/tests/v2_6_checks.sql", "utf8");
    assert.match(sql, /public\.save_consultation/);
    assert.match(sql, /Гимназия: II\/1 е допустима/);
    assert.match(sql, /Прогимназия: I\/7 е допустима/);
    assert.match(sql, /Гимназия: I смяна се отказва/);
    assert.match(sql, /Прогимназия: II смяна се отказва/);
    assert.match(sql, /Смесени етапи се отказват/);
    assert.match(sql, /Обратна конфигурация: гимназия II, прогимназия I/);
    assert.match(sql, /rollback;/i);
});

/* ===================== v2.4: свързани смени, конфликти при попълване ===================== */

test("getOppositeShift: I <-> II", () => {
    assert.equal(L.getOppositeShift(1), 2);
    assert.equal(L.getOppositeShift(2), 1);
    assert.equal(L.getOppositeShift("1"), 2);
    assert.equal(L.getOppositeShift(L.getOppositeShift(1)), 1);
});

test("v2.6: смяната за консултации се извежда от редовната смяна на етапа", () => {
    const config = { gymnasium: 1, progymnasium: 2 };
    assert.equal(L.consultationShiftForStage("gymnasium", config), 2);
    assert.equal(L.consultationShiftForStage("progymnasium", config), 1);
    assert.equal(L.consultationShiftForStage("gymnasium", { gymnasium: 2, progymnasium: 1 }), 1);
    assert.equal(L.consultationShiftForStage("progymnasium", { gymnasium: 2, progymnasium: 1 }), 2);
    assert.deepEqual(L.evaluateStageShift(["8А"], 2, config),
        { ok: true, reason: "ok", stage: "gymnasium", expectedShift: 2 });
    assert.equal(L.evaluateStageShift(["8А"], 1, config).reason, "wrong_shift");
    assert.equal(L.evaluateStageShift(["5А"], 1, config).ok, true);
    assert.equal(L.evaluateStageShift(["5А"], 2, config).reason, "wrong_shift");
    assert.equal(L.evaluateStageShift(["5А", "10А"], 1, config).reason, "mixed_stages");
    assert.equal(L.evaluateStageShift(["4А"], 1, config).reason, "unknown_stage");
    assert.equal(L.evaluateStageShift(["8А"], 2, {}).reason, "missing_config");
});

const rec = (id, teacherId, day, shift, hour, subject, classes, location = "", teacher = "Иван Иванов") =>
    ({ id: String(id), teacherId, teacher, day, shift, hour, subject, location, classes });
const base = { day: "Понеделник", shift: 1, hour: 4, subject: "История", location: "", teacherId: "t2", groupSubjects: [] };

test("13/14: 10А, 10Б свободни, 10В конфликт – записват се свободните", () => {
    const records = [rec(1, "t1", "Понеделник", 1, 4, "Математика", ["10В"])];
    const ev = L.evaluateSelection(records, { ...base, classes: ["10А", "10Б", "10В"] });
    assert.deepEqual(ev.free, ["10А", "10Б"]);
    assert.deepEqual(ev.blocked, ["10В"]);
    assert.equal(ev.canSave, true);
    const msgs = L.summarizeSelection(ev);
    assert.equal(msgs[0].level, "warn");
    assert.match(msgs[0].text, /1 избран клас има конфликт\. Можете да продължите с останалите свободни класове\./);
});

test("15: конфликтът е конкретен (предмет, ден, смяна, час, учител)", () => {
    const records = [rec(1, "t1", "Понеделник", 1, 4, "Математика", ["10В"])];
    const ev = L.evaluateSelection(records, { ...base, classes: ["10В"] });
    const d = L.describeClassConflict("10В", ev.conflicts["10В"]);
    assert.equal(d.title, "⚠️ 10В вече има консултация.");
    assert.deepEqual(d.details, [["Предмет", "Математика"], ["Ден", "Понеделник"], ["Смяна", "I"],
                                 ["Час", "10:10 - 10:50"], ["Учител", "Иван Иванов"]]);
});

test("20/21: два конфликтни класа (мн.ч.) и всички класове в конфликт блокират записа", () => {
    const records = [rec(1, "t1", "Понеделник", 1, 4, "Математика", ["10В", "11Б"])];
    let ev = L.evaluateSelection(records, { ...base, classes: ["10А", "10В", "11Б"] });
    assert.match(L.summarizeSelection(ev)[0].text, /2 избрани класа имат конфликт\. Можете да продължите/);
    assert.equal(ev.canSave, true);
    ev = L.evaluateSelection(records, { ...base, classes: ["10В", "11Б"] });
    assert.equal(ev.canSave, false);
    assert.equal(ev.allBlocked, true);
    assert.match(L.summarizeSelection(ev)[0].text, /Всички избрани класове имат конфликт в този час\. Изберете друг час или премахнете конфликтните класове\./);
    ev = L.evaluateSelection(records, { ...base, classes: [] });
    assert.equal(ev.canSave, false);
    assert.match(L.summarizeSelection(ev)[0].text, /Изберете поне един клас/);
});

test("16: проверката се променя с часа, дните и предмета; свободен час = без предупреждение", () => {
    const records = [rec(1, "t1", "Понеделник", 1, 4, "Математика", ["10В"])];
    const at = over => L.evaluateSelection(records, { ...base, classes: ["10В"], ...over });
    assert.equal(at({}).canSave, false);                                    // зает
    assert.equal(at({ hour: 5 }).canSave, true);                            // друг час
    assert.equal(at({ day: "Вторник" }).canSave, true);                     // друг ден
    assert.equal(at({ shift: 2 }).canSave, true);                           // друга смяна
    assert.equal(L.summarizeSelection(at({ hour: 5 }))[0].text, "✓ Няма конфликти.");
});

test("18: слот = ден + смяна + час; I/7 и II/1 са независими за валидни етапи", () => {
    const records = [rec(1, "t1", "Понеделник", 1, 7, "Математика", ["5А"])];     // прогимназия, I/7
    // Гимназията използва II/1; един учител, предмет и място могат да съвпадат.
    assert.equal(L.evaluateSelection(records, { ...base, teacherId: "t1", subject: "Математика", shift: 2, hour: 1, classes: ["8А"] }).canSave, true);
    // Същият учител в същата логическа клетка (I/7) е конфликт.
    const sameCell = L.evaluateSelection(records, { ...base, teacherId: "t1", subject: "Физика", shift: 1, hour: 7, classes: ["5А"] });
    assert.ok(sameCell.teacherConflict);
    assert.equal(sameCell.canSave, false);
    // И обратно: II/1 не блокира I/7 за клас от прогимназията.
    const rev = [rec(2, "t1", "Понеделник", 2, 1, "Математика", ["8А"])];
    assert.equal(L.evaluateSelection(rev, { ...base, teacherId: "t1", shift: 1, hour: 7, classes: ["5А"] }).canSave, true);
});

test("19: паралелни групи – само в рамките на клетката", () => {
    const groups = ["ИТ"];
    const g = (id, shift, hour, loc, cls = "9А") => rec(id, "t" + id, "Вторник", shift, hour, "ИТ", [cls], loc);
    const p = { day: "Вторник", shift: 2, hour: 3, subject: "ИТ", location: "К2", teacherId: "t9", groupSubjects: groups, classes: ["9А"] };
    // една група с различно място – позволено
    assert.equal(L.evaluateSelection([g(1, 2, 3, "К1")], p).canSave, true);
    // същото място – конфликт
    const loc = L.evaluateSelection([g(1, 2, 3, "К2")], p);
    assert.equal(loc.canSave, false);
    assert.equal(loc.conflicts["9А"].type, "same_location");
    // две групи вече – пълно
    assert.equal(L.evaluateSelection([g(1, 2, 3, "К1"), g(2, 2, 3, "К3")], p).conflicts["9А"].type, "groups_full");
    // 12:35 I/7 за 5А е отделна клетка от II/1 за 9А.
    assert.equal(L.evaluateSelection([g(1, 1, 7, "К2", "5А"), g(2, 1, 7, "К3", "5А")], { ...p, shift: 2, hour: 1 }).canSave, true);
    // различен предмет в клетката – зает
    assert.equal(L.evaluateSelection([rec(5, "t5", "Вторник", 2, 3, "Физика", ["9А"], "К1")], p).conflicts["9А"].type, "occupied");
    // групов предмет изисква място
    const noLoc = L.evaluateSelection([], { ...p, location: "" });
    assert.equal(noLoc.needsLocation, true);
    assert.equal(noLoc.canSave, false);
});

test("редакция: собственият запис не е конфликт; маркери по класове", () => {
    const records = [rec(1, "t1", "Понеделник", 1, 4, "Математика", ["10В"])];
    assert.equal(L.evaluateSelection(records, { ...base, teacherId: "t1", excludeId: "1", classes: ["10В"] }).canSave, true);
    const m = L.classMarkers(records, { ...base, classes: ["10А"] }, ["10А", "10Б", "10В"]);
    assert.deepEqual(m, { "10А": "✓", "10Б": "", "10В": "⚠ Има конфликт" });
});

test("етапи на консултация и подредба по време", () => {
    assert.equal(L.stageNamesOfRecord({ classes: ["5А", "5Б"] }), "Прогимназиален");
    assert.equal(L.stageNamesOfRecord({ classes: ["8А"] }), "Гимназиален");
    assert.equal(L.stageNamesOfRecord({ classes: ["8А", "7А"] }), "Прогимназиален / Гимназиален");
    const sorted = [rec(1, "t", "Вторник", 1, 1, "Б", []), rec(2, "t", "Понеделник", 2, 1, "А", []),
                    rec(3, "t", "Понеделник", 1, 7, "А", []), rec(4, "t", "Понеделник", 1, 2, "А", [])].sort(L.compareRecordsByTime);
    assert.deepEqual(sorted.map(r => r.id), ["4", "3", "2", "1"]);
});

test("v2.6: frontend използва централната настройка, а server-side RPC остава авторитетна", () => {
    const dir = __dirname + "/../supabase/migrations/";
    assert.equal(fs.readdirSync(dir).sort().pop(), "20261009000000_stage_consultation_shifts.sql");
    const app = fs.readFileSync(__dirname + "/../js/app.js", "utf8");
    const storage = fs.readFileSync(__dirname + "/../js/storage.js", "utf8");
    assert.ok(/storage\.(add|update)\(/.test(app));                 // записът продължава през RPC
    assert.ok(/evaluateSelection\(storage\.getAll\(\), ctx\.params\)/.test(app));
    assert.ok(/evaluateStageShift\(ctx\.params\.classes, shift, storage\._stageRegularShifts\)/.test(app));
    assert.ok(/get_consultation_stage_shifts/.test(storage));
    assert.ok(/disabled/.test(app.slice(app.indexOf("function applyStageConsultationShift"), app.indexOf("function updateViewIndicator"))));
});
