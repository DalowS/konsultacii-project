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
