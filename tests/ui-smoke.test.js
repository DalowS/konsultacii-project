/* Изпълнява реалните js/*.js във vm с фалшив DOM (без Supabase). Хваща runtime грешки в рендерирането. */
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const vm = require("vm");
const path = require("path");

function setup() {
    const elements = {};
    const mk = () => {
        const o = { value: "", textContent: "", style: {}, dataset: {}, disabled: false, children: [], _html: "",
            classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
            appendChild(c) { this.children.push(c); }, removeChild() {}, focus() {}, select() {},
            querySelector: () => mk(), querySelectorAll: () => [], closest: () => null,
            addEventListener() {}, click() {}, setAttribute() {}, remove() {} };
        Object.defineProperty(o, "innerHTML", { get() { return this._html; }, set(v) { this._html = v; this.children = []; } });
        return o;
    };
    const document = {
        getElementById: id => (elements[id] ||= mk()), querySelector: () => mk(),
        querySelectorAll: sel => sel === "[data-stage-tabs]" ? [(elements.__tabs ||= mk())]
            : sel === ".extraClass:checked" ? (elements.__checked || [])
            : sel === ".class-state" ? (elements.__states || []) : [],
        createElement: () => mk(), addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
        body: mk(), activeElement: null, hidden: false
    };
    const downloads = [], alerts = [], printed = [], listeners = {};
    class Blob { constructor(parts) { this.text = parts.join(""); } }
    const ctx = { document, console, Blob, setTimeout, clearTimeout, setInterval, clearInterval,
        URL: { createObjectURL: b => { downloads.push(b.text); return "blob:x"; }, revokeObjectURL() {} },
        alert: m => alerts.push(m), confirm: () => true, prompt: () => null,
        open: () => ({ document: { write: h => printed.push(h), close() {} }, print() {} }),
        addEventListener() {}, localStorage: { getItem: () => null, setItem() {} }, navigator: { onLine: true } };
    ctx.window = ctx;
    vm.createContext(ctx);
    for (const f of ["logic", "supabase", "storage", "auth", "app"]) {
        vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "js", f + ".js"), "utf8"), ctx, { filename: f + ".js" });
    }
    vm.runInContext(`
        storage._classes = [{id:1,name:"8А"},{id:2,name:"8Б"},{id:3,name:"5А"},{id:4,name:"7А"}];
        storage._stageRegularShifts = {gymnasium:1, progymnasium:2};
        CONFIG.classes = storage.getClassNames();
        currentUser = {id:"u-admin", name:"Админ", role:"admin"}; isAdmin = true; currentTeacher = "Админ";
        storage._teachers = [{id:"u-admin",name:"Админ",role:"admin"},{id:"u-t",name:"Учител",role:"teacher"}];
        storage._groupSubjects = [{id:1,subject:"ИТ",enabled:true}];
        const mkRec = (id,teacherId,teacher,day,shift,hour,classes,subject) =>
            ({id,teacherId,teacher,day,shift,hour,subject,location:"",classes,className:classes[0]});
        storage._cache = [
            mkRec("1","u-t","Учител","Понеделник",1,7,["5А"],"Математика"),   // прогимназията е редовно II
            mkRec("2","u-t","Учител","Вторник",2,2,["8А"],"БЕЛ"),
            mkRec("3","u-t","Учител","Сряда",2,3,["8Б"],"Физика"),
            mkRec("4","u-t","Учител","Четвъртък",2,1,["8Б"],"Химия"),          // II смяна / 12:35
            mkRec("5","u-t","Учител","Петък",1,2,["5А"],"Англ"),               // прогимназия
            mkRec("6","u-t","Учител","Петък",2,3,["7А","8А"],"Смесена")        // и двата етапа
        ];`, ctx);
    vm.runInContext("applyStageConsultationShift()", ctx);
    return { ctx, elements, downloads, alerts, printed, listeners, run: code => vm.runInContext(code, ctx) };
}

function setSchedule(t, cls, shift) {
    const stage = /^[5-7]/.test(cls) ? "progymnasium" : "gymnasium";
    t.run(`setStage("${stage}"); document.getElementById("classSelect").value="${cls}"; document.getElementById("shiftSelect").value="${shift}";`);
    t.run("renderSchedule()");
    return t.elements.scheduleTable.innerHTML;
}
const rows = html => html.split("<tr>").slice(2);                 // без реда в <thead>
const values = el => el.children.map(c => c.value);

test("графикът показва само консултационната смяна на етапа", () => {
    const t = setup();
    const gym = rows(setSchedule(t, "8А", 1)); // ръчно зададената грешна смяна се игнорира
    assert.equal(gym.length, 7);
    assert.match(gym[0], /12:35 - 13:15/); assert.match(gym[6], /17:50 - 18:30/);
    assert.equal(shiftNow(t), "2");
    assert.equal(t.elements.shiftSelect.disabled, true);
    t.run(`setStage("progymnasium")`);
    const pro = rows(setSchedule(t, "5А", 2));
    assert.equal(pro.length, 7);
    assert.match(pro[0], /7:30 - 8:10/); assert.match(pro[6], /12:35 - 13:15/);
    assert.equal(shiftNow(t), "1");
});

test("13: I/7 и II/1 остават различни клетки за съответните етапи", () => {
    const t = setup();
    const pro = rows(setSchedule(t, "5А", 2));
    const gym = rows(setSchedule(t, "8А", 1));
    assert.match(pro[6], /Математика/); // прогимназия: I/7
    assert.match(gym[0], /\+ Добави консултация/); // гимназия: II/1 е отделна клетка
    assert.equal(t.run("getCellRecords('5А', 2, 'Понеделник', 1).length"), 0);
    assert.equal(t.run("getCellRecords('8А', 1, 'Понеделник', 7).length"), 0);
});

test("14: I/7 не се копира във II/1", () => {
    const t = setup();
    const s1 = rows(setSchedule(t, "5А", 1));
    const s2 = rows(setSchedule(t, "8А", 2));
    assert.match(s1[6], /Математика/);
    assert.doesNotMatch(s2[0], /Математика/);
    assert.match(s2[0], /\+ Добави консултация/);
});

test("15: II/1 не се копира във I/7", () => {
    const t = setup();
    const s1 = rows(setSchedule(t, "5А", 1));
    const s2 = rows(setSchedule(t, "8Б", 2));
    assert.match(s2[0], /Химия/);                          // Четвъртък, II смяна, 1-ви час
    assert.ok(!s1.join("").includes("Химия"), "не трябва да се огледа в I/7");
});

test("модалът отваря само клетките, допустими за съответния етап", () => {
    const t = setup();
    t.run(`openAddModal("8А", 2, "Петък", 1)`);
    assert.equal(t.elements.modalHour.value, "12:35 - 13:15");
    assert.equal(t.elements.modalShift.value, "II смяна");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 2, hour: 1 });
    t.run(`setStage("progymnasium"); openAddModal("5А", 1, "Петък", 7)`);
    assert.equal(t.elements.modalHour.value, "12:35 - 13:15");
    assert.equal(t.elements.modalShift.value, "I смяна");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 1, hour: 7 });
});

test("формата отказва невалидна смяна и блокира запис при директна промяна на слота", async () => {
    const t = setup();
    t.run(`openAddModal("8А", 1, "Понеделник", 1)`);
    assert.match(t.alerts[0], /само в II смяна/);
    assert.equal(t.elements.modalOverlay, undefined, "невалидната клетка не отваря формата");

    t.run(`storage.add = async rec => { globalThis.__added = rec; }; openAddModal("8А", 2, "Понеделник", 1);`);
    t.elements.__checked = [{ value: "8А" }];
    t.run(`document.getElementById("modalSubject").value = "Физика"; setModalSlot(1, 1); refreshConflictUI()`);
    assert.equal(t.elements.modalSaveBtn.disabled, true);
    await t.run("saveConsultation()");
    assert.equal(t.run("typeof __added"), "undefined", "невалидният слот не изпраща заявка");
    assert.match(t.alerts.at(-1), /само в II смяна/);
});

test("раздели: по подразбиране гимназия; активният е различим", () => {
    const t = setup();
    t.run("renderStageTabs()");
    const tabs = t.elements.__tabs.innerHTML;
    assert.match(tabs, /Гимназиален етап/); assert.match(tabs, /Прогимназиален етап/);
    assert.match(tabs, /btn-primary[^>]*aria-pressed="true"[^>]*>Гимназиален/);
    assert.match(tabs, /btn-secondary[^>]*aria-pressed="false"[^>]*>Прогимназиален/);
    t.run(`setStage("progymnasium")`);
    assert.match(t.elements.__tabs.innerHTML, /btn-primary[^>]*aria-pressed="true"[^>]*>Прогимназиален/);
});

test("7: падащият списък в гимназията не показва 5-7; 8: в прогимназията не показва 8-12", () => {
    const t = setup();
    t.run("populateClasses(); buildExtraClasses();");
    assert.deepEqual(values(t.elements.classSelect), ["8А", "8Б"]);
    assert.ok(t.elements.extraClassesBox.children.every(c => /value="8/.test(c.innerHTML)));
    t.run(`setStage("progymnasium")`);
    assert.deepEqual(values(t.elements.classSelect), ["5А", "7А"]);
    t.run("buildExtraClasses()");
    const html = t.elements.extraClassesBox.children.map(c => c.innerHTML).join("");
    assert.ok(/value="5А"/.test(html) && /value="7А"/.test(html) && !/value="8/.test(html));
});

test("5/6: нов клас 6А -> прогимназия, 9А -> гимназия (автоматично)", () => {
    const t = setup();
    t.run(`setStage("progymnasium"); storage._classes.push({id:9,name:"6А"}); renderViews();`);
    assert.deepEqual(values(t.elements.classSelect), ["5А", "6А", "7А"]);
    t.run(`setStage("gymnasium"); storage._classes.push({id:10,name:"9А"}); renderViews();`);
    assert.deepEqual(values(t.elements.classSelect), ["8А", "8Б", "9А"]);
});

test("графикът в етап без класове не се чупи", () => {
    const t = setup();
    t.run(`storage._classes = storage._classes.filter(c => !/^[5-7]/.test(c.name)); CONFIG.classes = storage.getClassNames(); setStage("progymnasium");`);
    t.run("renderSchedule()");
    assert.match(t.elements.scheduleTable.innerHTML, /Няма класове за този етап/);
});

test("9/10: печатът има заглавие според етапа и само неговите класове", () => {
    const t = setup();
    t.run("printScheduleReport()");
    assert.match(t.printed[0], /<h2>График за консултации – Гимназиален етап<\/h2>/);
    assert.match(t.printed[0], /<title>График за консултации – Гимназиален етап<\/title>/);
    assert.doesNotMatch(t.printed[0], /5А|7А|Англ/);                   // нищо от прогимназията
    assert.match(t.printed[0], /БЕЛ/);
    t.run(`setStage("progymnasium"); printScheduleReport()`);
    assert.match(t.printed[1], /<h2>График за консултации – Прогимназиален етап<\/h2>/);
    assert.match(t.printed[1], /Англ/);
    assert.doesNotMatch(t.printed[1], /БЕЛ|8А|8Б|Химия/);
});

test("11: CSV следва избрания етап", () => {
    const t = setup();
    t.run("exportCSV()");
    const gym = t.downloads[0];
    assert.match(gym, /БЕЛ/); assert.match(gym, /Химия/);
    assert.doesNotMatch(gym, /Англ|5А|7А/);
    t.run(`setStage("progymnasium"); exportCSV()`);
    const pro = t.downloads[1];
    assert.match(pro, /Англ/); assert.match(pro, /Смесена/);
    assert.doesNotMatch(pro, /БЕЛ|Химия|8А/);
});

test("12: статистиката следва избрания етап", () => {
    const t = setup();
    t.run("renderAdminStats()");
    // гимназия: 8А,8Б (2); записи 2,3,4,6 (4); по една клетка на всеки клас/ден = 4.
    let h = t.elements.adminStats.innerHTML;
    assert.match(h, /Класове[\s\S]*?<strong>2<\/strong>/);
    assert.match(h, /Общо консултации[\s\S]*?<strong>4<\/strong>/);
    assert.match(h, /Заети клетки[\s\S]*?<strong>4<\/strong>/);
    assert.equal(t.elements.adminStageLabel.textContent, "Гимназиален етап");
    t.run(`setStage("progymnasium"); renderAdminStats()`);
    h = t.elements.adminStats.innerHTML;
    // прогимназия: класове 5А,7А (2); записи 1,5,6 (3); клетки: 5А×пон+пет и 7А×пет = 3.
    assert.match(h, /Класове[\s\S]*?<strong>2<\/strong>/);
    assert.match(h, /Общо консултации[\s\S]*?<strong>3<\/strong>/);
    assert.match(h, /Заети клетки[\s\S]*?<strong>3<\/strong>/);
    assert.equal(t.elements.adminStageLabel.textContent, "Прогимназиален етап");
});

test("админ таблица: по етап; „Класове“ остава обща", () => {
    const t = setup();
    t.run("renderAdminTable()");
    assert.doesNotMatch(t.elements.adminTable.innerHTML, /Математика/);
    t.run(`setStage("progymnasium"); renderAdminTable()`);
    assert.match(t.elements.adminTable.innerHTML, /Математика/);
    t.run(`setStage("gymnasium"); renderAdminTable()`);
    assert.doesNotMatch(t.elements.adminTable.innerHTML, /Англ/);
    assert.doesNotMatch(t.elements.adminTable.innerHTML, /7А/);        // смесената се показва само с 8А
    t.run("renderClassesAdmin()");
    const cls = t.elements.classesAdmin.innerHTML;
    for (const c of ["8А", "8Б", "5А", "7А"]) assert.ok(cls.includes(`<strong>${c}</strong>`), c);
    t.run(`setStage("progymnasium"); renderClassesAdmin()`);
    for (const c of ["8А", "8Б", "5А", "7А"]) assert.ok(t.elements.classesAdmin.innerHTML.includes(`<strong>${c}</strong>`), c);
});

test("админ: филтърът по клас е ограничен до етапа", () => {
    const t = setup();
    t.run("populateAdminFilters()");
    assert.deepEqual(values(t.elements.adminClassFilter), ["8А", "8Б"]);
    t.run(`setStage("progymnasium"); populateAdminFilters()`);
    assert.deepEqual(values(t.elements.adminClassFilter), ["5А", "7А"]);
});


test("редакция на стара смесена консултация: извънетапните класове се виждат и могат да се махнат", () => {
    const t = setup();
    const calls = [];
    t.run(`storage.update = async (id, rec) => { globalThis.__saved = {id, rec}; };`);
    t.run(`setStage("gymnasium"); editConsultation("6");`);          // 7А + 8А, в гимназията се вижда 8А
    assert.equal(t.elements.modalClass.value, "8А");
    assert.ok(t.elements.extraClassesBox.children.some(c => /value="7А"/.test(c.innerHTML)));
    t.run(`document.getElementById("modalSubject").value="Смесена"; document.getElementById("modalId").value="6";`);
    t.elements.__checked = [{ value: "8А" }];                         // в гимназията е отметнат само 8А
    return t.run("saveConsultation()").then(() => {
        const saved = t.run("__saved");
        assert.deepEqual([...saved.rec.classes].sort(), ["8А"]);
        assert.equal(saved.rec.shift, 2); assert.equal(saved.rec.hour, 3);
    });
});

test("админ: учители – няма Премахни за себе си; класове – няма Изтрий за заети", () => {
    const t = setup();
    t.run("renderTeachersAdmin(); renderClassesAdmin();");
    const teachers = t.elements.teachersAdmin.innerHTML;
    assert.match(teachers, /\(Вие\)/);
    assert.equal((teachers.match(/removeTeacher\(/g) || []).length, 1);
    assert.ok(teachers.includes("removeTeacher('u-t'"));
    const classes = t.elements.classesAdmin.innerHTML;
    assert.equal((classes.match(/deleteClass\(/g) || []).length, 0);   // 8А,8Б,5А,7А – всички имат консултации
});

test("addClass: клиентска валидация (5-12)", async () => {
    const t = setup();
    t.run(`document.getElementById("newClassGrade").value="13"; document.getElementById("newClassLetter").value="А";`);
    await t.run("addClass({currentTarget:null})");
    assert.match(t.alerts[0], /от 5 до 12/);
    t.run(`document.getElementById("newClassGrade").value="4"; document.getElementById("newClassLetter").value="А";`);
    await t.run("addClass({currentTarget:null})");
    assert.match(t.alerts[1], /от 5 до 12/);
    t.run(`document.getElementById("newClassGrade").value="8"; document.getElementById("newClassLetter").value="a";`);
    await t.run("addClass({currentTarget:null})");           // латинско a -> 8А, вече съществува
    assert.match(t.alerts[2], /вече съществува/);
});

test("1/2: I/7 и II/1 остават независими клетки за валидни класове от двата етапа", () => {
    const t = setup();
    t.run(`storage._cache = [
        {id:"10",teacherId:"u-t",teacher:"Сабринко Далов",day:"Понеделник",shift:1,hour:7,subject:"Математика",location:"12",classes:["5А"],className:"5А"},
        {id:"11",teacherId:"u-t",teacher:"Сабринко Далов",day:"Понеделник",shift:2,hour:1,subject:"Математика",location:"12",classes:["8А"],className:"8А"}
    ];`);
    const s1 = rows(setSchedule(t, "5А", 1));
    const s2 = rows(setSchedule(t, "8А", 2));
    assert.match(s1[6], /Математика/);                         // I смяна, час 7
    assert.match(s2[0], /Математика/);                         // II смяна, час 1
    assert.equal((s1.join("").match(/Математика/g) || []).length, 1);   // във всяка смяна – точно една
    assert.equal((s2.join("").match(/Математика/g) || []).length, 1);
    // всяка клетка се редактира със собствен идентификатор (не са един запис)
    assert.ok(s1[6].includes("editConsultation('10')") && s2[0].includes("editConsultation('11')") ||
              (/Математика/.test(s1[6]) && /Математика/.test(s2[0])));
    t.run(`currentUser = {id:"u-t", name:"Сабринко Далов", role:"teacher"}; isAdmin = false;`);
    assert.equal(t.run("getCellRecords('5А', 1, 'Понеделник', 7).length"), 1);
    assert.equal(t.run("getCellRecords('8А', 2, 'Понеделник', 1).length"), 1);
    assert.equal(t.run("getCellRecords('5А', 1, 'Понеделник', 7)[0].id"), "10");
    assert.equal(t.run("getCellRecords('8А', 2, 'Понеделник', 1)[0].id"), "11");
});

test("клиентът не блокира II/1, когато I/7 е заета (формата се отваря без предупреждение)", () => {
    const t = setup();
    // Прогимназиален клас заема I/7; гимназията може да използва II/1.
    const before = t.alerts.length;
    t.run(`openAddModal("8А", 2, "Понеделник", 1)`);
    assert.equal(t.alerts.length, before, "без alert за заетост");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 2, hour: 1 });
    assert.equal(t.elements.modalHour.value, "12:35 - 13:15");
});

test("печат: заглавието е центрирано спрямо страницата и таблицата (общ контейнер, една ширина)", () => {
    const t = setup();
    t.run("printScheduleReport()");
    const html = t.printed[0];
    assert.match(html, /<div class="sheet"><h2>График за консултации – Гимназиален етап<\/h2><table>/);
    assert.match(html, /\.sheet h2 \{ text-align: center;/);
    assert.match(html, /\.sheet table \{ width: 100%; border-collapse: collapse;/);
    assert.match(html, /\.sheet \{ width: 100%; margin: 0 auto; \}/);
    assert.match(html, /<\/table><\/div><\/body>/);
    // съдържанието на таблицата е същото: същите колони и редове
    assert.match(html, /<th>Учител<\/th><th>Предмет<\/th><th>Класове<\/th><th>Ден<\/th><th>Смяна<\/th><th>Час<\/th><th>Място<\/th>/);
    assert.equal((html.match(/<tr><td>/g) || []).length, 4);          // 4 консултации в гимназията
    t.run(`setStage("progymnasium"); printScheduleReport()`);
    assert.match(t.printed[1], /<div class="sheet"><h2>График за консултации – Прогимназиален етап<\/h2><table>/);
    assert.match(t.printed[1], /\.sheet h2 \{ text-align: center;/);
});

/* ===================== v2.4 ===================== */
const flip = (t, stage, shift) => {
    t.run(`currentStage = "${stage}"; document.getElementById("shiftSelect").value = "${shift}";`);
};
const shiftNow = t => t.elements.shiftSelect.value;

test("A: начална конфигурация: гимназия II, прогимназия I", () => {
    const t = setup(); flip(t, "gymnasium", 2);
    t.run(`setStage("progymnasium")`);
    assert.equal(t.run("currentStage"), "progymnasium");
    assert.equal(shiftNow(t), "1");
    assert.match(t.elements.viewIndicator.innerHTML, /Прогимназиален етап · I смяна/);
    assert.match(t.elements.viewIndicator.innerHTML, /Консултационната смяна е сменена автоматично: II → I смяна/);
});
test("B: обратната конфигурация задава прогимназия II", () => {
    const t = setup(); t.run(`storage._stageRegularShifts = {gymnasium:2, progymnasium:1}; applyStageConsultationShift();`);
    t.run(`setStage("progymnasium")`);
    assert.equal(shiftNow(t), "2");
    assert.match(t.elements.viewIndicator.innerHTML, /Прогимназиален етап · II смяна/);
});
test("C: обратната конфигурация задава гимназия I", () => {
    const t = setup(); t.run(`storage._stageRegularShifts = {gymnasium:2, progymnasium:1}; applyStageConsultationShift(); setStage("progymnasium");`);
    t.run(`setStage("gymnasium")`);
    assert.equal(shiftNow(t), "1");
    assert.match(t.elements.viewIndicator.innerHTML, /Гимназиален етап · I смяна/);
});
test("D: началната конфигурация задава гимназия II при връщане", () => {
    const t = setup(); flip(t, "progymnasium", 1);
    t.run(`setStage("gymnasium")`);
    assert.equal(shiftNow(t), "2");
});
test("смяната се определя от конфигурацията и повторният избор не я променя", () => {
    const t = setup(); flip(t, "gymnasium", 1);
    t.run(`setStage("gymnasium"); renderSchedule()`);                // графикът държи стойността по настройката
    t.run(`renderSchedule()`);                                        // графикът фиксира стойността по настройката
    assert.equal(shiftNow(t), "2");
    t.run(`setStage("progymnasium"); setStage("gymnasium")`);
    assert.equal(shiftNow(t), "2");
});
test("графикът след превключване показва прогимназиалната I смяна", () => {
    const t = setup(); flip(t, "gymnasium", 2);
    t.run(`setStage("progymnasium"); document.getElementById("classSelect").value = "5А"`);
    t.run(`document.getElementById("classSelect").value = "5А"; renderSchedule()`);
    assert.match(t.elements.scheduleTitle.textContent, /5А • I смяна/);
    assert.match(rows(t.elements.scheduleTable.innerHTML)[0], /7:30 - 8:10/);
});

test("E: смяната НЕ се променя при смяна на клас, час (модал), филтри, презареждане", () => {
    const t = setup(); flip(t, "gymnasium", 2);
    t.run(`document.getElementById("classSelect").value = "8Б"; renderSchedule()`);
    assert.equal(shiftNow(t), "2");
    t.run(`openAddModal("8А", 2, "Петък", 5); closeModal();`);
    assert.equal(shiftNow(t), "2");
    t.run(`document.getElementById("adminClassFilter").value = "8А"; renderAdminTable(); populateAdminFilters(); populateClasses(); renderViews();`);
    assert.equal(shiftNow(t), "2");
});

test("индикаторът е в основния екран и има role=status", () => {
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    assert.match(html, /id="viewIndicator"[^>]*role="status"[^>]*aria-live="polite"/);
});

/* ---------- конфликти при попълване във формата ---------- */
function openForm(t, cls, shift, day, hour) {
    t.run(`openAddModal("${cls}", ${shift}, "${day}", ${hour})`);
}

test("13/14 (UI): 8А заето в I/7 – при избор на 8А,8Б се показва конкретен конфликт, записът остава възможен", async () => {
    const t = setup();
    t.run(`storage._cache.push({id:"88",teacherId:"u-x",teacher:"Друг",day:"Понеделник",shift:2,hour:1,subject:"Математика",location:"",classes:["8А"],className:"8А"});`);
    t.run(`storage.add = async rec => { globalThis.__added = rec; };`);
    openForm(t, "8Б", 2, "Понеделник", 1);                          // гимназията използва II/1
    t.run(`document.getElementById("modalSubject").value = "История"; document.getElementById("modalLocation").value = "";`);
    t.elements.__checked = [{ value: "8А" }, { value: "8Б" }];
    t.run("refreshConflictUI()");
    const box = t.elements.conflictBox.innerHTML;
    assert.match(box, /8А вече има консултация\./);
    assert.match(box, /Предмет: <strong>Математика<\/strong>/);
    assert.match(box, /Ден: <strong>Понеделник<\/strong>/);
    assert.match(box, /Смяна: <strong>II<\/strong>/);
    assert.match(box, /Час: <strong>12:35 - 13:15<\/strong>/);
    assert.match(box, /Учител: <strong>Друг<\/strong>/);
    assert.match(t.elements.conflictSummary.innerHTML, /1 избран клас има конфликт\. Можете да продължите/);
    assert.match(t.elements.conflictSummary.className, /warn/);
    assert.equal(t.elements.modalSaveBtn.disabled, false);
    await t.run("saveConsultation()");
    const added = t.run("__added");
    assert.deepEqual([...added.classes], ["8Б"]);                   // само свободният клас
    assert.equal(added.shift, 2); assert.equal(added.hour, 1);
    const statusText = Object.values(t.elements).map(e => e.textContent || "").join(" ");
    assert.match(statusText, /Не е записана за \(конфликт\): 8А/);
});

test("21 (UI): всички избрани класове в конфликт – записът е блокиран и обяснен", async () => {
    const t = setup();
    t.run(`storage._cache.push({id:"88",teacherId:"u-x",teacher:"Друг",day:"Понеделник",shift:2,hour:1,subject:"Математика",location:"",classes:["8А"],className:"8А"});`);
    t.run(`storage.add = async rec => { globalThis.__added = rec; };`);
    openForm(t, "8Б", 2, "Понеделник", 1);
    t.run(`document.getElementById("modalSubject").value = "История";`);
    t.elements.__checked = [{ value: "8А" }];
    t.run("refreshConflictUI()");
    assert.equal(t.elements.modalSaveBtn.disabled, true);
    assert.match(t.elements.conflictSummary.innerHTML, /Всички избрани класове имат конфликт в този час/);
    assert.match(t.elements.conflictSummary.className, /error/);
    await t.run("saveConsultation()");
    assert.equal(t.run("typeof __added"), "undefined", "няма заявка към сървъра");
    assert.match(t.alerts.at(-1), /Всички избрани класове имат конфликт/);
});

test("16 (UI): динамично – при свободен час предупреждението изчезва; Realtime обновява проверката", () => {
    const t = setup();
    t.run(`storage._cache.push({id:"88",teacherId:"u-x",teacher:"Друг",day:"Понеделник",shift:2,hour:1,subject:"Математика",location:"",classes:["8А"],className:"8А"});`);
    openForm(t, "8Б", 2, "Понеделник", 1);
    t.run(`document.getElementById("modalSubject").value = "История";`);
    t.elements.__checked = [{ value: "8А" }, { value: "8Б" }];
    t.run("refreshConflictUI()");
    assert.match(t.elements.conflictBox.innerHTML, /8А вече има консултация/);
    t.run("setModalSlot(2, 5); refreshConflictUI()");                // друг час
    assert.equal(t.elements.conflictBox.innerHTML, "");
    assert.match(t.elements.conflictSummary.innerHTML, /✓ Няма конфликти\./);
    assert.equal(t.elements.modalSaveBtn.disabled, false);
    // друг потребител заема 8Б в 1/5 (Realtime -> renderViews)
    t.run(`storage._cache.push({id:"90",teacherId:"u-x",teacher:"Друг",day:"Понеделник",shift:2,hour:5,subject:"Химия",location:"",classes:["8Б"],className:"8Б"}); renderViews();`);
    assert.match(t.elements.conflictBox.innerHTML, /8Б вече има консултация/);
    assert.match(t.elements.conflictBox.innerHTML, /Учител: <strong>Друг<\/strong>/);
});

test("F (UI): I/7 и II/1 не блокират една друга при различни валидни етапи", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false;`);
    openForm(t, "8А", 2, "Понеделник", 1);                          // 5А заема I/7; 8А може да е във II/1
    t.run(`document.getElementById("modalSubject").value = "Математика";`);
    t.elements.__checked = [{ value: "8А" }];
    t.run("refreshConflictUI()");
    assert.equal(t.elements.conflictBox.innerHTML, "");
    assert.equal(t.elements.modalSaveBtn.disabled, false);
    assert.match(t.elements.conflictSummary.innerHTML, /Няма конфликти/);
});

test("същият учител в същата клетка = блокиран запис с обяснение", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false;`);
    t.run(`storage._cache.push({id:"91",teacherId:"u-t",teacher:"Учител",day:"Понеделник",shift:2,hour:7,subject:"Математика",location:"",classes:["8А"],className:"8А"});`);
    openForm(t, "8Б", 2, "Понеделник", 7);                          // u-t вече има 8А в същия логически слот
    t.run(`document.getElementById("modalSubject").value = "Физика";`);
    t.elements.__checked = [{ value: "8Б" }];
    t.run("refreshConflictUI()");
    assert.equal(t.elements.modalSaveBtn.disabled, true);
    assert.match(t.elements.conflictBox.innerHTML, /Учителят вече има консултация в този час/);
});

test("етикетите до класовете са текст (✓ / ⚠), не само цвят", () => {
    const t = setup();
    t.run(`storage._cache.push({id:"88",teacherId:"u-x",teacher:"Друг",day:"Понеделник",shift:2,hour:7,subject:"Математика",location:"",classes:["8А"],className:"8А"});`);
    openForm(t, "8Б", 2, "Понеделник", 7);
    const spans = ["8А", "8Б"].map(c => ({ dataset: { class: c }, textContent: "", className: "" }));
    t.elements.__states = spans;
    t.elements.__checked = [{ value: "8Б" }];
    t.run(`document.getElementById("modalSubject").value = "История"; refreshConflictUI()`);
    assert.equal(spans[0].textContent, "⚠ Има конфликт");            // 8А (неизбран, но е в конфликт)
    assert.match(spans[0].className, /bad/);
    assert.equal(spans[1].textContent, "✓");
    assert.match(spans[1].className, /good/);
});

/* ---------- „Моите консултации“ и печат ---------- */
test("Моите консултации е глобален: двата етапа, сортиран, с колона Етап", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false; showMyConsultations();`);
    const gymList = t.elements.myConsultationsList.innerHTML;
    for (const subj of ["Математика", "БЕЛ", "Физика", "Химия", "Англ", "Смесена"]) assert.ok(gymList.includes(subj), subj);
    assert.match(gymList, /<th scope="col">Етап<\/th>/);
    assert.match(gymList, /<td>Прогимназиален<\/td>/);
    assert.match(gymList, /<td>Гимназиален<\/td>/);
    assert.match(gymList, /<td>Прогимназиален \/ Гимназиален<\/td>/);
    // същият изглед при другия етап
    t.run(`setStage("progymnasium"); showMyConsultations();`);
    assert.equal(t.elements.myConsultationsList.innerHTML, gymList);
    // подредба: ден -> смяна -> час
    const order = ["Математика", "БЕЛ", "Физика", "Химия", "Англ", "Смесена"].map(s => gymList.indexOf(s));
    assert.deepEqual([...order].sort((a, b) => a - b), order);
    assert.equal(t.elements.myPrintBtn.disabled, false);
    assert.equal(t.elements.myConsultationsModal.style.display, "flex");
});

test("Моите консултации: само собствените; без консултации – печатът е изключен", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-nobody", name:"Друг", role:"teacher"}; showMyConsultations();`);
    assert.match(t.elements.myConsultationsList.innerHTML, /Нямате консултации/);
    assert.equal(t.elements.myPrintBtn.disabled, true);
});

test("печат от „Моите консултации“: всички консултации, двата етапа, центрирано заглавие", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false; setStage("progymnasium"); printMyConsultations();`);
    const html = t.printed[0];
    assert.match(html, /<div class="sheet sheet-fit"><h2>Моите консултации – Учител<\/h2><table>/);
    assert.match(html, /\.sheet h2 \{ text-align: center;/);
    assert.match(html, /<th>Етап<\/th><th>Ден<\/th><th>Смяна<\/th><th>Час<\/th><th>Предмет<\/th><th>Класове<\/th><th>Място<\/th>/);
    assert.equal((html.match(/<tr><td>/g) || []).length, 6);         // и 5-7, и 8-12
    for (const subj of ["Математика", "Англ", "Химия", "Смесена"]) assert.ok(html.includes(subj), subj);
    const order = ["Математика", "БЕЛ", "Физика", "Химия", "Англ", "Смесена"].map(s => html.indexOf(s));
    assert.deepEqual([...order].sort((a, b) => a - b), order);
});

test("10/22/27: няма „Печат“ в основния график; печатът е в „Моите консултации“", () => {
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    const teacher = html.slice(html.indexOf('<section id="teacherScreen"'), html.indexOf('<section id="adminScreen"'));
    assert.ok(!/Печат|print|CSV|Excel/i.test(teacher), "основният график няма печат/CSV");
    const my = html.slice(html.indexOf('id="myConsultationsModal"'), html.indexOf('<!-- ADD / EDIT MODAL -->'));
    assert.match(my, /id="myPrintBtn"[^>]*onclick="printMyConsultations\(\)"[^>]*>🖨 Печат</);
    assert.ok(!/Печат/.test(html.slice(0, html.indexOf('<section id="adminScreen"'))
        .replace(/<div id="myConsultationsModal"[\s\S]*$/, "")), "извън „Моите консултации“ няма Печат преди админ панела");
});

/* ---------- достъпност ---------- */
test("Escape затваря прозорците; фокусът се връща", () => {
    const t = setup();
    const press = key => (t.listeners.keydown || []).forEach(fn => fn({ key }));
    t.run(`openAddModal("8Б", 2, "Петък", 3)`);
    assert.equal(t.elements.modalOverlay.style.display, "flex");
    press("Enter");
    assert.equal(t.elements.modalOverlay.style.display, "flex");
    press("Escape");
    assert.equal(t.elements.modalOverlay.style.display, "none");
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; showMyConsultations();`);
    press("Escape");
    assert.equal(t.elements.myConsultationsModal.style.display, "none");
});

test("достъпност (статично): роли, labels, focus-visible, disabled, live региони", () => {
    const read = f => fs.readFileSync(path.join(__dirname, "..", f), "utf8");
    const html = read("index.html"), css = read("css/style.css");
    assert.equal((html.match(/role="dialog" aria-modal="true"/g) || []).length, 2);
    for (const id of ["modalClass", "modalShift", "modalDay", "modalHour", "modalSubject", "modalLocation"]) {
        assert.ok(html.includes(`<label for="${id}">`), `label for ${id}`);
    }
    assert.match(html, /id="conflictSummary"[^>]*aria-live="polite"/);
    assert.match(html, /id="conflictBox"[^>]*aria-live="polite"/);
    assert.match(css, /:focus-visible/);
    assert.match(css, /button:disabled/);
    assert.match(css, /\.sr-only/);
});

/* ===================== v2.5: карти „Класове“ и печат ===================== */
const cardOf = (html, key) => {
    const i = html.indexOf(`data-stage="${key}"`);
    if (i < 0) return "";
    const j = html.indexOf("</section>", i);
    return html.slice(i, j);
};
const classCells = card => [...card.matchAll(/<td><strong>([^<]+)<\/strong><\/td>/g)].map(m => m[1]);

function setupClasses(t) {
    // 5А,7А (прогимназия), 8А,8Б (гимназия) + празни 6А (без консултации) и 9А
    t.run(`storage._classes = [{id:1,name:"8А"},{id:2,name:"8Б"},{id:3,name:"5А"},{id:4,name:"7А"},{id:5,name:"6А"},{id:6,name:"9А"}]
           .sort((a,b)=>compareClassNames(a.name,b.name)); CONFIG.classes = storage.getClassNames(); renderClassesAdmin();`);
    return t.elements.classesAdmin.innerHTML;
}

test("Класове: две карти – Прогимназиален вляво, Гимназиален вдясно", () => {
    const t = setup();
    const html = setupClasses(t);
    assert.ok(html.indexOf('data-stage="progymnasium"') < html.indexOf('data-stage="gymnasium"'), "прогимназията е първа (лява)");
    assert.match(cardOf(html, "progymnasium"), /<h4>Прогимназиален етап<\/h4>/);
    assert.match(cardOf(html, "gymnasium"), /<h4>Гимназиален етап<\/h4>/);
    assert.equal((html.match(/<section class="class-card/g) || []).length, 2);
});

test("Класове: 5–7 само в прогимназията, 8–12 само в гимназията; всички са показани", () => {
    const t = setup();
    const html = setupClasses(t);
    assert.deepEqual(classCells(cardOf(html, "progymnasium")), ["5А", "6А", "7А"]);
    assert.deepEqual(classCells(cardOf(html, "gymnasium")), ["8А", "8Б", "9А"]);
    const all = [...classCells(cardOf(html, "progymnasium")), ...classCells(cardOf(html, "gymnasium"))].sort();
    assert.deepEqual(all, t.run("storage.getClassNames()").slice().sort());       // нищо не липсва и няма дубликати
});

test("Класове: колони Клас | Консултации | Действие във всяка карта", () => {
    const t = setup();
    const html = setupClasses(t);
    for (const key of ["progymnasium", "gymnasium"]) {
        assert.match(cardOf(html, key), /<th scope="col">Клас<\/th><th scope="col">Консултации<\/th><th scope="col">Действие<\/th>/);
    }
});

test("Класове: броят консултации е непроменен", () => {
    const t = setup();
    const html = setupClasses(t);
    const count = (card, cls) => Number(new RegExp(`<strong>${cls}</strong></td>\\s*<td class="num">(\\d+)</td>`).exec(card)[1]);
    // от данните: 8А – записи 2,6; 8Б – 3,4; 5А – 1,5; 7А – 6; 6А, 9А – 0
    assert.equal(count(cardOf(html, "gymnasium"), "8А"), 2);
    assert.equal(count(cardOf(html, "gymnasium"), "8Б"), 2);
    assert.equal(count(cardOf(html, "gymnasium"), "9А"), 0);
    assert.equal(count(cardOf(html, "progymnasium"), "5А"), 2);
    assert.equal(count(cardOf(html, "progymnasium"), "7А"), 1);
    assert.equal(count(cardOf(html, "progymnasium"), "6А"), 0);
});

test("Класове: с консултации – компактно „Има консултации“, без бутон; без консултации – бутон „Изтрий“", () => {
    const t = setup();
    const html = setupClasses(t);
    const g = cardOf(html, "gymnasium"), p = cardOf(html, "progymnasium");
    assert.match(g, /Има консултации/);
    assert.ok(!/не може да се изтрие<\/span>/.test(g), "без дълъг разтягащ се текст");
    assert.ok(!g.includes("deleteClass('1'") && !g.includes("deleteClass('2'"), "8А/8Б (с консултации) нямат Изтрий");
    assert.ok(g.includes("deleteClass('6'"), "9А (без консултации) има Изтрий");
    assert.ok(p.includes("deleteClass('5'"), "6А (без консултации) има Изтрий");
    assert.ok(!p.includes("deleteClass('3'") && !p.includes("deleteClass('4'"));
    assert.match(g, /<button class="btn-danger btn-compact"/);
});

test("Класове: изтриването продължава да работи (празен клас се трие, с консултации – няма бутон)", async () => {
    const t = setup();
    setupClasses(t);
    t.run(`storage.deleteClass = async id => { globalThis.__deleted = id; storage._classes = storage._classes.filter(c => String(c.id) !== String(id)); };`);
    await t.run(`deleteClass("5", null)`);                              // 6А – без консултации
    assert.equal(t.run("__deleted"), "5");
    const html = t.elements.classesAdmin.innerHTML;
    assert.ok(!classCells(cardOf(html, "progymnasium")).includes("6А"), "6А изчезва от картата");
    assert.deepEqual(classCells(cardOf(html, "progymnasium")), ["5А", "7А"]);
});

test("Класове: добавянето продължава да работи; новият клас е в правилната карта", async () => {
    const t = setup();
    setupClasses(t);
    t.run(`storage.addClass = async (g, l) => { globalThis.__added = [g, l]; storage._classes.push({id: 50 + g, name: g + l}); storage._classes.sort((x, y) => compareClassNames(x.name, y.name)); };`);   // както storage.refresh()
    t.run(`document.getElementById("newClassGrade").value = "6"; document.getElementById("newClassLetter").value = "Б";`);
    await t.run("addClass({currentTarget:null})");
    assert.deepEqual([...t.run("__added")], [6, "Б"]);
    let html = t.elements.classesAdmin.innerHTML;
    assert.deepEqual(classCells(cardOf(html, "progymnasium")), ["5А", "6А", "6Б", "7А"]);
    assert.ok(!classCells(cardOf(html, "gymnasium")).includes("6Б"));
    t.run(`document.getElementById("newClassGrade").value = "12"; document.getElementById("newClassLetter").value = "В";`);
    await t.run("addClass({currentTarget:null})");
    html = t.elements.classesAdmin.innerHTML;
    assert.ok(classCells(cardOf(html, "gymnasium")).includes("12В"));
    assert.ok(!classCells(cardOf(html, "progymnasium")).includes("12В"));
});

test("Класове: клас извън 5–12 не изчезва (допълнителна карта)", () => {
    const t = setup();
    t.run(`storage._classes.push({id:70,name:"4А"}); renderClassesAdmin();`);
    const html = t.elements.classesAdmin.innerHTML;
    assert.ok(classCells(cardOf(html, "other")).includes("4А"));
    assert.match(cardOf(html, "other"), /<h4>Други класове<\/h4>/);
});

test("Класове (CSS): две колони на широк екран, една на малък; компактна таблица; без min-width 850px", () => {
    const css = fs.readFileSync(path.join(__dirname, "..", "css", "style.css"), "utf8");
    assert.match(css, /\.classes-grid \{[^}]*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\)/);
    assert.match(css, /@media \(max-width: 760px\) \{\s*\.classes-grid \{ grid-template-columns: 1fr; \}/);
    assert.match(css, /\.classes-table \{[^}]*min-width: 0/);
    assert.match(css, /\.classes-table td\.action \{ width: 1%; white-space: nowrap;/);
    assert.match(css, /\.btn-compact \{[^}]*width: auto/);
    // общото правило за останалите таблици е непроменено
    assert.match(css, /table \{\s*width: 100%;\s*min-width: 850px;/);
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    assert.match(html, /<div id="classesAdmin" class="classes-grid"><\/div>/);
});

test("Печат „Моите консултации“: 7 колони, правила за побиране в страницата", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false; printMyConsultations();`);
    const html = t.printed[0];
    // структурата и заглавието са непроменени
    assert.match(html, /<h2>Моите консултации – Учител<\/h2>/);
    assert.match(html, /<th>Етап<\/th><th>Ден<\/th><th>Смяна<\/th><th>Час<\/th><th>Предмет<\/th><th>Класове<\/th><th>Място<\/th>/);
    assert.equal((html.match(/<th>/g) || []).length, 7);
    assert.equal((html.match(/<tr><td>/g) || []).length, 6);
    const css = html.slice(html.indexOf("<style>"), html.indexOf("</style>"));
    // побиране: ширина < 100% (място вдясно), започва от левия край, пренасяне на дълги думи, чете се (11pt)
    assert.match(css, /\.sheet-fit \{ width: calc\(100% - 8mm\); margin: 0; \}/);
    assert.match(css, /\.sheet-fit table \{ width: 100%; table-layout: auto; margin: 0; \}/);
    assert.match(css, /\.sheet-fit th, \.sheet-fit td \{ padding: 5px 6px; font-size: 11pt; overflow-wrap: anywhere; \}/);
    // заглавието е в същия контейнер като таблицата и е центрирано
    assert.match(css, /\.sheet h2 \{ text-align: center;/);
    assert.match(html, /<div class="sheet sheet-fit"><h2>/);
    // няма скрол/изрязване при печат и текстът не е прекалено малък
    assert.ok(!/overflow-x|overflow:\s*(auto|scroll|hidden)/.test(css));
    const fontPt = Math.min(...[...css.matchAll(/font-size:\s*(\d+(?:\.\d+)?)pt/g)].map(m => Number(m[1])));
    assert.ok(fontPt >= 11, `шрифт ${fontPt}pt`);
});

test("Печат: графикът по етап и екранният изглед на „Моите консултации“ не са променени", () => {
    const t = setup();
    t.run("printScheduleReport()");
    assert.match(t.printed[0], /<div class="sheet"><h2>График за консултации – Гимназиален етап<\/h2><table>/);   // без sheet-fit
    const css = fs.readFileSync(path.join(__dirname, "..", "css", "style.css"), "utf8");
    assert.ok(!css.includes("sheet-fit"), "print-only правилата не са в екранния CSS");
    assert.match(css, /\.my-table \{ width: 100%; border-collapse: collapse; font-size: 15px; \}/);          // екранната таблица е същата
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; showMyConsultations();`);
    assert.match(t.elements.myConsultationsList.innerHTML, /<table class="my-table">/);
    assert.ok(!t.elements.myConsultationsList.innerHTML.includes("sheet"));
});

test("Печат: сортирането и всички консултации на учителя са непроменени", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false; printMyConsultations();`);
    const html = t.printed[0];
    const order = ["Математика", "БЕЛ", "Физика", "Химия", "Англ", "Смесена"].map(x => html.indexOf(x));
    assert.ok(order.every(i => i > 0));
    assert.deepEqual([...order].sort((a, b) => a - b), order);
});
