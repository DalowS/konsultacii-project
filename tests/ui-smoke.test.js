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
        CONFIG.classes = storage.getClassNames();
        currentUser = {id:"u-admin", name:"Админ", role:"admin"}; isAdmin = true; currentTeacher = "Админ";
        storage._teachers = [{id:"u-admin",name:"Админ",role:"admin"},{id:"u-t",name:"Учител",role:"teacher"}];
        storage._groupSubjects = [{id:1,subject:"ИТ",enabled:true}];
        const mkRec = (id,teacherId,teacher,day,shift,hour,classes,subject) =>
            ({id,teacherId,teacher,day,shift,hour,subject,location:"",classes,className:classes[0]});
        storage._cache = [
            mkRec("1","u-t","Учител","Понеделник",1,7,["8А"],"Математика"),   // I смяна / 12:35
            mkRec("2","u-t","Учител","Вторник",2,2,["8А"],"БЕЛ"),
            mkRec("3","u-t","Учител","Сряда",1,3,["8Б"],"Физика"),
            mkRec("4","u-t","Учител","Четвъртък",2,1,["8Б"],"Химия"),          // II смяна / 12:35
            mkRec("5","u-t","Учител","Петък",1,2,["5А"],"Англ"),               // прогимназия
            mkRec("6","u-t","Учител","Петък",2,3,["7А","8А"],"Смесена")        // и двата етапа
        ];`, ctx);
    return { ctx, elements, downloads, alerts, printed, listeners, run: code => vm.runInContext(code, ctx) };
}

function setSchedule(t, cls, shift) {
    t.run(`document.getElementById("classSelect").value="${cls}"; document.getElementById("shiftSelect").value="${shift}";`);
    t.run("renderSchedule()");
    return t.elements.scheduleTable.innerHTML;
}
const rows = html => html.split("<tr>").slice(2);                 // без реда в <thead>
const values = el => el.children.map(c => c.value);

test("графикът: 7 реда за всяка смяна с правилните часове", () => {
    const t = setup();
    const s1 = rows(setSchedule(t, "8А", 1));
    const s2 = rows(setSchedule(t, "8А", 2));
    assert.equal(s1.length, 7); assert.equal(s2.length, 7);
    // избрана I смяна -> 12:35-18:30; избрана II смяна -> 7:30-13:15
    assert.match(s1[0], /12:35–13:15/); assert.match(s1[6], /17:50–18:30/);
    assert.match(s2[0], /07:30–08:10/);   assert.match(s2[6], /12:35–13:15/);
});

test("13: I смяна/12:35 и II смяна/12:35 са отделни клетки", () => {
    const t = setup();
    const s1 = rows(setSchedule(t, "8А", 1));
    const s2 = rows(setSchedule(t, "8А", 2));
    // и двете клетки имат свой бутон „Добави“ със собствена смяна/час
    assert.ok(s1[6].includes("openAddModal('8А', 1, 'Понеделник', 7)") || /Математика/.test(s1[6]));
    assert.ok(s2[0].includes("openAddModal('8А', 2, 'Понеделник', 1)"), "II/1 е празна и самостоятелна");
    assert.doesNotMatch(s2[0].split("</td>").slice(1, 2).join(""), /Математика/);
});

test("14: консултация в I смяна/12:35 НЕ се копира във II смяна/12:35", () => {
    const t = setup();
    const s1 = rows(setSchedule(t, "8А", 1));
    const s2 = rows(setSchedule(t, "8А", 2));
    assert.match(s1[6], /Математика/);                     // Понеделник, I смяна, 7-ми час
    assert.ok(!s2.join("").includes("Математика"), "не трябва да се огледа във II смяна");
    assert.doesNotMatch(s2[0], /Математика/);
    assert.match(s2[0], /\+ Добави консултация/);          // II/1 за понеделник е свободна
});

test("15: консултация във II смяна/12:35 НЕ се копира в I смяна/12:35", () => {
    const t = setup();
    const s1 = rows(setSchedule(t, "8Б", 1));
    const s2 = rows(setSchedule(t, "8Б", 2));
    assert.match(s2[0], /Химия/);                          // Четвъртък, II смяна, 1-ви час
    assert.ok(!s1.join("").includes("Химия"), "не трябва да се огледа в I смяна");
    assert.doesNotMatch(s1[6], /Химия/);
});

test("модал: смяна и час за двете клетки на 12:35", () => {
    const t = setup();
    t.run(`openAddModal("8А", 2, "Петък", 1)`);
    assert.equal(t.elements.modalHour.value, "07:30–08:10");
    assert.equal(t.elements.modalShift.value, "II смяна");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 2, hour: 1 });
    t.run(`openAddModal("8А", 1, "Петък", 7)`);
    assert.equal(t.elements.modalHour.value, "17:50–18:30");
    assert.equal(t.elements.modalShift.value, "I смяна");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 1, hour: 7 });
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
    assert.match(t.printed[0], /Математика/);
    t.run(`setStage("progymnasium"); printScheduleReport()`);
    assert.match(t.printed[1], /<h2>График за консултации – Прогимназиален етап<\/h2>/);
    assert.match(t.printed[1], /Англ/);
    assert.doesNotMatch(t.printed[1], /Математика|8А|8Б|Химия/);
});

test("11: CSV следва избрания етап", () => {
    const t = setup();
    t.run("exportCSV()");
    const gym = t.downloads[0];
    assert.match(gym, /Математика/); assert.match(gym, /Химия/);
    assert.doesNotMatch(gym, /Англ|5А|7А/);
    t.run(`setStage("progymnasium"); exportCSV()`);
    const pro = t.downloads[1];
    assert.match(pro, /Англ/); assert.match(pro, /Смесена/);
    assert.doesNotMatch(pro, /Математика|Химия|8А/);
});

test("12: статистиката следва избрания етап", () => {
    const t = setup();
    t.run("renderAdminStats()");
    // гимназия: класове 8А,8Б (2); записи 1,2,3,4,6 (5); клетки: 8А×(пон,вт,пет) + 8Б×(сря,чет) = 5; учители 1
    let h = t.elements.adminStats.innerHTML;
    assert.match(h, /Класове[\s\S]*?<strong>2<\/strong>/);
    assert.match(h, /Общо консултации[\s\S]*?<strong>5<\/strong>/);
    assert.match(h, /Заети клетки[\s\S]*?<strong>5<\/strong>/);
    assert.equal(t.elements.adminStageLabel.textContent, "Гимназиален етап");
    t.run(`setStage("progymnasium"); renderAdminStats()`);
    h = t.elements.adminStats.innerHTML;
    // прогимназия: класове 5А,7А (2); записи 5,6 (2); клетки: 5А×пет + 7А×пет = 2
    assert.match(h, /Класове[\s\S]*?<strong>2<\/strong>/);
    assert.match(h, /Общо консултации[\s\S]*?<strong>2<\/strong>/);
    assert.match(h, /Заети клетки[\s\S]*?<strong>2<\/strong>/);
    assert.equal(t.elements.adminStageLabel.textContent, "Прогимназиален етап");
});

test("админ таблица: по етап; „Класове“ остава обща", () => {
    const t = setup();
    t.run("renderAdminTable()");
    assert.match(t.elements.adminTable.innerHTML, /Математика/);
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


test("редакция на смесена консултация: извънетапните класове се запазват", () => {
    const t = setup();
    const calls = [];
    t.run(`storage.update = async (id, rec) => { globalThis.__saved = {id, rec}; };`);
    t.run(`setStage("gymnasium"); editConsultation("6");`);          // 7А + 8А, в гимназията се вижда 8А
    assert.equal(t.elements.modalClass.value, "8А");
    t.run(`document.getElementById("modalSubject").value="Смесена"; document.getElementById("modalId").value="6";`);
    t.elements.__checked = [{ value: "8А" }];                         // в гимназията е отметнат само 8А
    return t.run("saveConsultation()").then(() => {
        const saved = t.run("__saved");
        assert.deepEqual([...saved.rec.classes].sort(), ["7А", "8А"]);
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

test("1/2: едни и същи консултации в I/7 и II/1 (учител, предмет, класове, място) са независими", () => {
    const t = setup();
    t.run(`storage._cache = [
        {id:"10",teacherId:"u-t",teacher:"Сабринко Далов",day:"Понеделник",shift:1,hour:7,subject:"Математика",location:"12",classes:["8А","8Б"],className:"8А"},
        {id:"11",teacherId:"u-t",teacher:"Сабринко Далов",day:"Понеделник",shift:2,hour:1,subject:"Математика",location:"12",classes:["8А","8Б"],className:"8А"}
    ];`);
    const s1 = rows(setSchedule(t, "8А", 1));
    const s2 = rows(setSchedule(t, "8А", 2));
    assert.match(s1[6], /Математика/);                         // I смяна, час 7
    assert.match(s2[0], /Математика/);                         // II смяна, час 1
    assert.equal((s1.join("").match(/Математика/g) || []).length, 1);   // във всяка смяна – точно една
    assert.equal((s2.join("").match(/Математика/g) || []).length, 1);
    // всяка клетка се редактира със собствен идентификатор (не са един запис)
    assert.ok(s1[6].includes("editConsultation('10')") && s2[0].includes("editConsultation('11')") ||
              (/Математика/.test(s1[6]) && /Математика/.test(s2[0])));
    t.run(`currentUser = {id:"u-t", name:"Сабринко Далов", role:"teacher"}; isAdmin = false;`);
    assert.equal(t.run("getCellRecords('8А', 1, 'Понеделник', 7).length"), 1);
    assert.equal(t.run("getCellRecords('8А', 2, 'Понеделник', 1).length"), 1);
    assert.equal(t.run("getCellRecords('8А', 1, 'Понеделник', 7)[0].id"), "10");
    assert.equal(t.run("getCellRecords('8А', 2, 'Понеделник', 1)[0].id"), "11");
});

test("клиентът не блокира II/1, когато I/7 е заета (формата се отваря без предупреждение)", () => {
    const t = setup();
    // 8А, Понеделник, I смяна/7 е заета (запис 1)
    const before = t.alerts.length;
    t.run(`openAddModal("8А", 2, "Понеделник", 1)`);
    assert.equal(t.alerts.length, before, "без alert за заетост");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 2, hour: 1 });
    assert.equal(t.elements.modalHour.value, "07:30–08:10");
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
    assert.equal((html.match(/<tr><td>/g) || []).length, 5);          // 5 консултации в гимназията
    t.run(`setStage("progymnasium"); printScheduleReport()`);
    assert.match(t.printed[1], /<div class="sheet"><h2>График за консултации – Прогимназиален етап<\/h2><table>/);
    assert.match(t.printed[1], /\.sheet h2 \{ text-align: center;/);
});

/* ===================== v2.4 ===================== */
const flip = (t, stage, shift) => {
    t.run(`currentStage = "${stage}"; document.getElementById("shiftSelect").value = "${shift}";`);
};
const shiftNow = t => t.elements.shiftSelect.value;

test("A: Гимназиален I смяна -> Прогимназиален = II смяна", () => {
    const t = setup(); flip(t, "gymnasium", 1);
    t.run(`setStage("progymnasium")`);
    assert.equal(t.run("currentStage"), "progymnasium");
    assert.equal(shiftNow(t), "2");
    assert.match(t.elements.viewIndicator.innerHTML, /Прогимназиален етап · II смяна/);
    assert.match(t.elements.viewIndicator.innerHTML, /Смяната е сменена автоматично: I → II смяна/);
});
test("B: Гимназиален II смяна -> Прогимназиален = I смяна", () => {
    const t = setup(); flip(t, "gymnasium", 2);
    t.run(`setStage("progymnasium")`);
    assert.equal(shiftNow(t), "1");
    assert.match(t.elements.viewIndicator.innerHTML, /Прогимназиален етап · I смяна/);
});
test("C: Прогимназиален I смяна -> Гимназиален = II смяна", () => {
    const t = setup(); flip(t, "progymnasium", 1);
    t.run(`setStage("gymnasium")`);
    assert.equal(shiftNow(t), "2");
    assert.match(t.elements.viewIndicator.innerHTML, /Гимназиален етап · II смяна/);
});
test("D: Прогимназиален II смяна -> Гимназиален = I смяна", () => {
    const t = setup(); flip(t, "progymnasium", 2);
    t.run(`setStage("gymnasium")`);
    assert.equal(shiftNow(t), "1");
});
test("двойно превключване връща началната смяна; същият етап не обръща", () => {
    const t = setup(); flip(t, "gymnasium", 1);
    t.run(`setStage("gymnasium")`);                                  // същият етап – без промяна
    assert.equal(shiftNow(t), "1");
    t.run(`setStage("progymnasium"); setStage("gymnasium")`);
    assert.equal(shiftNow(t), "1");
});
test("графикът след превключване показва новата смяна (II) – 12:35 е първи ред", () => {
    const t = setup(); flip(t, "gymnasium", 1);
    t.run(`document.getElementById("classSelect").value = "5А"; setStage("progymnasium")`);
    t.run(`document.getElementById("classSelect").value = "5А"; renderSchedule()`);
    assert.match(t.elements.scheduleTitle.textContent, /5А • II смяна/);
    assert.match(rows(t.elements.scheduleTable.innerHTML)[0], /07:30–08:10/);   // II смяна -> часовете на I
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
    t.run(`storage.add = async rec => { globalThis.__added = rec; };`);
    openForm(t, "8Б", 1, "Понеделник", 7);                          // 8А е заето от „Математика“ (запис 1)
    t.run(`document.getElementById("modalSubject").value = "История"; document.getElementById("modalLocation").value = "";`);
    t.elements.__checked = [{ value: "8А" }, { value: "8Б" }];
    t.run("refreshConflictUI()");
    const box = t.elements.conflictBox.innerHTML;
    assert.match(box, /8А вече има консултация\./);
    assert.match(box, /Предмет: <strong>Математика<\/strong>/);
    assert.match(box, /Ден: <strong>Понеделник<\/strong>/);
    assert.match(box, /Смяна: <strong>I<\/strong>/);
    assert.match(box, /Час: <strong>17:50 - 18:30<\/strong>/);
    assert.match(box, /Учител: <strong>Учител<\/strong>/);
    assert.match(t.elements.conflictSummary.innerHTML, /1 избран клас има конфликт\. Можете да продължите/);
    assert.match(t.elements.conflictSummary.className, /warn/);
    assert.equal(t.elements.modalSaveBtn.disabled, false);
    await t.run("saveConsultation()");
    const added = t.run("__added");
    assert.deepEqual([...added.classes], ["8Б"]);                   // само свободният клас
    assert.equal(added.shift, 1); assert.equal(added.hour, 7);
    const statusText = Object.values(t.elements).map(e => e.textContent || "").join(" ");
    assert.match(statusText, /Не е записана за \(конфликт\): 8А/);
});

test("21 (UI): всички избрани класове в конфликт – записът е блокиран и обяснен", async () => {
    const t = setup();
    t.run(`storage.add = async rec => { globalThis.__added = rec; };`);
    openForm(t, "8Б", 1, "Понеделник", 7);
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
    openForm(t, "8Б", 1, "Понеделник", 7);
    t.run(`document.getElementById("modalSubject").value = "История";`);
    t.elements.__checked = [{ value: "8А" }, { value: "8Б" }];
    t.run("refreshConflictUI()");
    assert.match(t.elements.conflictBox.innerHTML, /8А вече има консултация/);
    t.run("setModalSlot(1, 5); refreshConflictUI()");                // друг час
    assert.equal(t.elements.conflictBox.innerHTML, "");
    assert.match(t.elements.conflictSummary.innerHTML, /✓ Няма конфликти\./);
    assert.equal(t.elements.modalSaveBtn.disabled, false);
    // друг потребител заема 8Б в 1/5 (Realtime -> renderViews)
    t.run(`storage._cache.push({id:"90",teacherId:"u-x",teacher:"Друг",day:"Понеделник",shift:1,hour:5,subject:"Химия",location:"",classes:["8Б"],className:"8Б"}); renderViews();`);
    assert.match(t.elements.conflictBox.innerHTML, /8Б вече има консултация/);
    assert.match(t.elements.conflictBox.innerHTML, /Учител: <strong>Друг<\/strong>/);
});

test("F (UI): I/12:35 не блокира II/12:35 – същият учител, предмет, клас", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false;`);
    openForm(t, "8А", 2, "Понеделник", 1);                          // 8А е заето в I/7, не във II/1
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
    openForm(t, "8Б", 1, "Понеделник", 7);                          // u-t вече има 8А в I/7
    t.run(`document.getElementById("modalSubject").value = "Физика";`);
    t.elements.__checked = [{ value: "8Б" }];
    t.run("refreshConflictUI()");
    assert.equal(t.elements.modalSaveBtn.disabled, true);
    assert.match(t.elements.conflictBox.innerHTML, /Учителят вече има консултация в този час/);
});

test("етикетите до класовете са текст (✓ / ⚠), не само цвят", () => {
    const t = setup();
    openForm(t, "8Б", 1, "Понеделник", 7);
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
    t.run(`openAddModal("8Б", 1, "Петък", 3)`);
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
    // от данните: 8А – записи 1,2,6; 8Б – 3,4; 5А – 5; 7А – 6; 6А, 9А – 0
    assert.equal(count(cardOf(html, "gymnasium"), "8А"), 3);
    assert.equal(count(cardOf(html, "gymnasium"), "8Б"), 2);
    assert.equal(count(cardOf(html, "gymnasium"), "9А"), 0);
    assert.equal(count(cardOf(html, "progymnasium"), "5А"), 1);
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
    assert.match(css, /\ntable \{\s*width: 100%;\s*min-width: 780px;/);
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
    assert.match(css, /\.my-table \{[^}]*border-collapse: collapse/);          // екранната таблица е само стил (печатът е в PRINT_CSS)
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

/* ===================== v2.7: изборът на смяна е свободен ===================== */
test("v2.7 т.1/2 (статично): #shiftSelect има I и II, не е disabled/readonly, няма код който го заключва", () => {
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    const sel = html.match(/<select id="shiftSelect"[^>]*>[\s\S]*?<\/select>/)[0];
    assert.match(sel, /<option value="1">I смяна<\/option>/);
    assert.match(sel, /<option value="2">II смяна<\/option>/);
    assert.doesNotMatch(sel, /disabled|readonly/i);
    const app = fs.readFileSync(path.join(__dirname, "..", "js", "app.js"), "utf8");
    assert.doesNotMatch(app, /shiftSelect["'`)\]]*\)?\.(disabled|readOnly)\s*=/);
    assert.doesNotMatch(app, /shiftSelect[^\n]*setAttribute\(\s*["']disabled/);
});

test("v2.7 т.1-3: потребителят избира I и II смяна във всеки етап; часовите интервали следват смяната", () => {
    const t = setup();
    for (const [stage, cls] of [["gymnasium", "8А"], ["progymnasium", "5А"]]) {
        t.run(`currentStage = "${stage}"; populateClasses();`);
        const r1 = rows(setSchedule(t, cls, 1));
        assert.equal(shiftNow(t), "1");
        assert.match(r1[0], /12:35–13:15/); assert.match(r1[6], /17:50–18:30/);
        const r2 = rows(setSchedule(t, cls, 2));
        assert.equal(shiftNow(t), "2");
        assert.match(r2[0], /07:30–08:10/); assert.match(r2[6], /12:35–13:15/);
        const r1b = rows(setSchedule(t, cls, 1));                 // и обратно – не е „залепнала“
        assert.match(r1b[0], /12:35–13:15/);
        assert.match(t.elements.viewIndicator.innerHTML, /I смяна/);
    }
});

test("v2.7 т.4/5: етапът обръща смяната, денят/класът/формата – не; ръчният избор след обръщане се пази", () => {
    const t = setup(); flip(t, "gymnasium", 1);
    t.run(`setStage("progymnasium")`); assert.equal(shiftNow(t), "2");
    t.run(`document.getElementById("shiftSelect").value = "1"; renderSchedule()`);     // ръчно обратно на I
    assert.equal(shiftNow(t), "1");
    t.run(`document.getElementById("classSelect").value = "7А"; renderSchedule(); openAddModal("7А", 1, "Вторник", 2); closeModal(); populateClasses();`);
    assert.equal(shiftNow(t), "1");
    t.run(`setStage("gymnasium")`); assert.equal(shiftNow(t), "2");
    t.run(`setStage("progymnasium")`); assert.equal(shiftNow(t), "1");
});

test("v2.7 т.6: след презареждане (запомнен етап) изборът на смяна остава свободен", () => {
    const t = setup();
    t.run(`localStorage.getItem = () => "progymnasium"; loadStagePreference(); populateClasses(); renderViews();`);
    assert.equal(t.run("currentStage"), "progymnasium");
    for (const s of [2, 1, 2]) {
        const r = rows(setSchedule(t, "5А", s));
        assert.equal(shiftNow(t), String(s));
        assert.match(r[0], s === 1 ? /12:35–13:15/ : /07:30–08:10/);
    }
});

test("v2.7 т.7: I/7 и II/1 са независими клетки в UI (консултация в едната не се показва в другата)", () => {
    const t = setup();
    const r1 = rows(setSchedule(t, "8А", 1)), r2 = rows(setSchedule(t, "8А", 2));
    assert.match(r1[6], /Математика/);          // I/7 понеделник
    assert.doesNotMatch(r2[0], /Математика/);   // II/1 празна
});

/* ===================== v2.8: избраната смяна показва интервалите на ПРОТИВОПОЛОЖНАТА ===================== */
const range = html => { const r = rows(html); return [r[0].match(/\d+:\d+–\d+:\d+/)[0], r[6].match(/\d+:\d+–\d+:\d+/)[0]]; };

test("v2.8: избрана I смяна -> 12:35–18:30; избрана II смяна -> 7:30–13:15", () => {
    const t = setup();
    assert.deepEqual(range(setSchedule(t, "8А", 1)), ["12:35–13:15", "17:50–18:30"]);
    assert.deepEqual(range(setSchedule(t, "8А", 2)), ["07:30–08:10", "12:35–13:15"]);
    assert.equal(rows(setSchedule(t, "8А", 1)).length, 7);
});

test("v2.8: ръчна промяна I -> II и II -> I веднага сменя часовете; изборът остава свободен", () => {
    const t = setup();
    t.run(`document.getElementById("classSelect").value = "8А"; document.getElementById("shiftSelect").value = "1"; renderSchedule()`);
    assert.equal(range(t.elements.scheduleTable.innerHTML)[0], "12:35–13:15");
    t.run(`document.getElementById("shiftSelect").value = "2"; renderSchedule()`);          // ръчно I -> II
    assert.equal(shiftNow(t), "2");
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["07:30–08:10", "12:35–13:15"]);
    t.run(`document.getElementById("shiftSelect").value = "1"; renderSchedule()`);          // ръчно II -> I
    assert.equal(shiftNow(t), "1");
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["12:35–13:15", "17:50–18:30"]);
});

test("v2.8: примери 1-4 (етап + смяна -> диапазон)", () => {
    const t = setup();
    // 1: Прогимназиален, II смяна -> 07:30–13:15
    flip(t, "progymnasium", 2); t.run("populateClasses()");
    assert.deepEqual(range(setSchedule(t, "5А", 2)), ["07:30–08:10", "12:35–13:15"]);
    // 2: към Гимназиален -> смяната II -> I, часове 12:35–18:30
    t.run(`setStage("gymnasium")`);
    assert.equal(shiftNow(t), "1");
    t.run(`document.getElementById("classSelect").value = "8А"; renderSchedule()`);
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["12:35–13:15", "17:50–18:30"]);
    // 3: Гимназиален, ръчно II -> остава II, 07:30–13:15
    t.run(`document.getElementById("shiftSelect").value = "2"; renderSchedule()`);
    assert.equal(shiftNow(t), "2");
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["07:30–08:10", "12:35–13:15"]);
    // 4: Прогимназиален, ръчно I -> остава I, 12:35–18:30
    t.run(`setStage("progymnasium")`);
    assert.equal(shiftNow(t), "1");
    t.run(`document.getElementById("classSelect").value = "5А"; document.getElementById("shiftSelect").value = "1"; renderSchedule()`);
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["12:35–13:15", "17:50–18:30"]);
});

test("v2.8: смяна на етап I -> II и II -> I обръща и смяната, и диапазона", () => {
    const t = setup();
    flip(t, "gymnasium", 1);
    t.run(`setStage("progymnasium"); document.getElementById("classSelect").value = "5А"; renderSchedule()`);
    assert.equal(shiftNow(t), "2");
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["07:30–08:10", "12:35–13:15"]);
    t.run(`setStage("gymnasium"); document.getElementById("classSelect").value = "8А"; renderSchedule()`);
    assert.equal(shiftNow(t), "1");
    assert.deepEqual(range(t.elements.scheduleTable.innerHTML), ["12:35–13:15", "17:50–18:30"]);
});

test("v2.8: клетките са по избраната смяна (ключ day+shift+hour), не по показвания диапазон", () => {
    const t = setup();
    const r1 = rows(setSchedule(t, "8А", 1)), r2 = rows(setSchedule(t, "8А", 2));
    // запис 1 е (Понеделник, shift 1, hour 7) -> показва се в 7-ия ред на ИЗБРАНА I смяна (17:50), не при II
    assert.match(r1[6], /Математика/); assert.match(r1[6], /17:50–18:30/);
    assert.doesNotMatch(r2.join(""), /Математика/);
    // бутоните и формата носят реалната избрана смяна
    assert.ok(r2[0].includes("openAddModal('8А', 2, 'Понеделник', 1)"));
    t.run(`openAddModal("8А", 2, "Понеделник", 1)`);
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 2, hour: 1 });
    assert.equal(t.elements.modalShift.value, "II смяна");
    assert.equal(t.elements.modalHour.value, "07:30–08:10");
    // I/7 (17:50) и II/1 (7:30) остават независими: заетата I/7 не блокира II/1
    assert.equal(t.run(`evaluateSelection(storage.getAll(), {day:"Понеделник",shift:2,hour:1,subject:"Математика",teacherId:"u-t",classes:["8А"],groupSubjects:[]}).canSave`), true);
    assert.equal(t.run(`evaluateSelection(storage.getAll(), {day:"Понеделник",shift:1,hour:7,subject:"Физика",teacherId:"u-t",classes:["8А"],groupSubjects:[]}).canSave`), false);
});

test("v2.8 (статично): shiftSelect не е заключен; конфликтният код не ползва positionLabel/labelIndex", () => {
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    assert.doesNotMatch(html.match(/<select id="shiftSelect"[^>]*>/)[0], /disabled|readonly|hidden/i);
    const logic = fs.readFileSync(path.join(__dirname, "..", "js", "logic.js"), "utf8");
    const conflict = logic.slice(logic.indexOf("const sameCell"), logic.indexOf("function evaluateSelection"));
    assert.doesNotMatch(conflict, /positionLabel|labelIndex|TIME_SLOTS/);
    assert.match(conflict, /r\.day === p\.day && Number\(r\.shift\) === Number\(p\.shift\) && Number\(r\.hour\) === Number\(p\.hour\)/);
});

/* ===================== v2.8 визуален редизайн (само външен вид) ===================== */
test("редизайн: ред „Консултации: …“ се изчислява от смяната (12:35–18:30 / 07:30–13:15); смяната остава свободна", () => {
    const t = setup();
    t.run(`document.getElementById("shiftSelect").value = "1"; updateViewIndicator()`);
    assert.match(t.elements.viewIndicator.innerHTML, /Консултации: <b>12:35–18:30<\/b>/);
    t.run(`document.getElementById("shiftSelect").value = "2"; updateViewIndicator()`);
    assert.match(t.elements.viewIndicator.innerHTML, /Консултации: <b>07:30–13:15<\/b>/);
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    assert.doesNotMatch(html.match(/<select id="shiftSelect"[^>]*>/)[0], /disabled|readonly|hidden/i);
    assert.equal(t.run(`formatTimeRange("7:30 - 8:10")`), "07:30–08:10");
    assert.equal(t.run(`formatTimeRange("12:35 - 13:15")`), "12:35–13:15");
});

test("редизайн: печатът е изолиран от екранния CSS (прозорецът за печат не зарежда css/style.css)", () => {
    const t = setup();
    t.run("printScheduleReport()");
    assert.doesNotMatch(t.printed[0], /style\.css|<link/);
    assert.match(t.printed[0], /<style>[\s\S]*@page/);
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; printMyConsultations();`);
    assert.doesNotMatch(t.printed[t.printed.length - 1], /style\.css|<link/);
    // CSV и печат ползват непроменените интервали („12:35 - 13:15“), форматът 12:35–13:15 е само на екрана
    assert.match(t.printed[t.printed.length - 1], /\d+:\d+ - \d+:\d+/);
});

test("редизайн (статично): всички id/onclick, нужни на JS, са запазени; фокусът е видим; няма градиенти и големи сенки", () => {
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    const css = fs.readFileSync(path.join(__dirname, "..", "css", "style.css"), "utf8");
    const app = fs.readFileSync(path.join(__dirname, "..", "js", "app.js"), "utf8");
    const ids = [...app.matchAll(/getElementById\("([A-Za-z0-9_]+)"\)/g)].map(m => m[1]);
    const dynamic = new Set(["adminStats", "restoreFile"]);
    for (const id of new Set(ids)) assert.ok(html.includes(`id="${id}"`) || dynamic.has(id) || app.includes(`id="${id}"`) || app.includes(`id='${id}'`), "липсва id: " + id);
    assert.match(css, /:focus-visible\s*\{[^}]*outline/);
    assert.doesNotMatch(css, /gradient/);
    assert.doesNotMatch(css, /box-shadow:[^;]*\b[3-9]\dpx/);   // без големи сенки (над 30px)
    assert.doesNotMatch(css, /animation|@keyframes/);
    assert.equal((html.match(/<\/head>/g) || []).length, 1);
    assert.equal((html.match(/<body>/g) || []).length, 1);
});

/* ===================== v2.9: header, sidebar, настройки, профил, регистрация ===================== */
const html9 = () => fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const css9 = () => fs.readFileSync(path.join(__dirname, "..", "css", "style.css"), "utf8");
const SETTINGS = { school_name: "СУ „Св. Паисий Хилендарски“ – Пловдив", academic_year: "2026/2027", current_term: "I" };
// фалшив classList със състояние – за проверка на видимост/скриване
const realClassList = (el, initial = []) => {
    const set = new Set(initial);
    el.classList = { add: c => set.add(c), remove: c => set.delete(c), contains: c => set.has(c),
                     toggle(c, on) { (on === undefined ? !set.has(c) : on) ? set.add(c) : set.delete(c); } };
    return set;
};

test("v2.9 header: срок/година и име на училището идват от настройките, не са във HTML/JS", () => {
    const t = setup();
    t.run(`storage._settings = ${JSON.stringify(SETTINGS)}; renderHeader();`);
    assert.equal(t.elements.headerTerm.textContent, "I срок · 2026/2027");
    assert.equal(t.elements.headerSchool.textContent, SETTINGS.school_name);
    // промяна в настройките -> заглавната лента следва
    t.run(`storage._settings = {school_name:"Друго училище", academic_year:"2027/2028", current_term:"II"}; renderHeader();`);
    assert.equal(t.elements.headerSchool.textContent, "Друго училище");
    assert.equal(t.elements.headerTerm.textContent, "II срок · 2027/2028");
    // без настройки (миграцията още не е приложена) – нищо измислено
    t.run(`storage._settings = null; renderHeader();`);
    assert.equal(t.elements.headerSchool.textContent, "");
    assert.equal(t.elements.headerTerm.textContent, "");
    // статично: нищо hard-coded
    const html = html9(), code = ["app.js", "logic.js", "storage.js"].map(f => fs.readFileSync(path.join(__dirname, "..", "js", f), "utf8")).join("\n");
    assert.doesNotMatch(html, /Св\. Паисий|Пловдив/);
    assert.doesNotMatch(code.replace(/\/\/[^\n]*/g, ""), /Св\. Паисий|Пловдив|schoolName\s*=\s*["']/);
    assert.match(html, /<div id="headerSchool" class="header-school"><\/div>/);
    assert.doesNotMatch(html.match(/<h1>[^<]*<\/h1>/)[0], /20\d\d/);
});

test("v2.9 header: потребител „Име · Роля“ за администратор и учител", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-me", name:"Мария Петрова", role:"admin"}; currentTeacher = "Мария Петрова"; isAdmin = true; renderHeader();`);
    assert.equal(t.elements.headerUser.textContent, "Мария Петрова · Администратор");
    t.run(`currentUser = {id:"u-t", name:"Георги Иванов", role:"teacher"}; currentTeacher = "Георги Иванов"; isAdmin = false; renderHeader();`);
    assert.equal(t.elements.headerUser.textContent, "Георги Иванов · Учител");
    t.run(`currentUser = null; currentTeacher = ""; renderHeader();`);
    assert.equal(t.elements.headerUser.textContent, "");
});

test("v2.9 header: училището е центрирано спрямо лентата (равни странични колони), навигацията не е в header-а", () => {
    const css = css9(), html = html9();
    assert.match(css, /\.header-inner \{[^}]*grid-template-columns: 1fr auto 1fr/);
    assert.match(css, /\.header-school \{[^}]*justify-self: center/);
    const header = html.match(/<header[\s\S]*?<\/header>/)[0];
    assert.doesNotMatch(header, /showMyConsultations|showAdminScreen|showTeacherScreen/);
    assert.match(header, /onclick="logout\(\)"/);
});

test("v2.9 sidebar: групи, елементи, запазени handler-и", () => {
    const html = html9();
    const side = html.match(/<aside id="sidebar"[\s\S]*?<\/aside>/)[0];
    for (const needle of ["График", "Моите консултации", "Администрация", "Настройки", "Потребители", "Класове", "Профил", "Смяна на парола", "Изход",
        "showTeacherScreen()", "showMyConsultations()", "showAdminScreen('settings')", "showAdminScreen('users')", "showAdminScreen('classes')", "showProfileScreen('password')", "logout()"])
        assert.ok(side.includes(needle), needle);
    assert.match(side, /id="adminToolbarBlock" class="nav-group hidden"/);     // администрацията е скрита по подразбиране
    // старите контроли в изгледите са запазени
    for (const id of ["classSelect", "shiftSelect", "scheduleTable", "viewIndicator", "adminTable", "classesAdmin", "teachersAdmin", "groupSubjectsContainer"])
        assert.ok(html.includes(`id="${id}"`), id);
});

test("v2.9 sidebar: показва се само след вход; admin групата – само за admin; активен елемент", () => {
    const t = setup();
    const body = new Set();
    t.run("document.body").classList = { add() {}, remove() {}, contains: c => body.has(c), toggle(c, on) { on ? body.add(c) : body.delete(c); } };
    const adminNav = t.run('document.getElementById("adminToolbarBlock")'); const navSet = realClassList(adminNav, ["hidden"]);
    t.run(`showScreen("loginScreen")`);   assert.equal(body.has("authed"), false);
    t.run(`showScreen("loadingScreen")`); assert.equal(body.has("authed"), false);
    t.run(`isAdmin = false; showTeacherScreen()`);
    assert.equal(body.has("authed"), true);
    assert.equal(navSet.has("hidden"), true, "teacher не вижда Администрация");
    t.run(`currentUser = {id:"u-me", name:"Мария", role:"admin"}; isAdmin = true; showTeacherScreen()`);
    assert.equal(navSet.has("hidden"), false, "admin вижда Администрация");
    t.run(`showScreen("loginScreen")`); assert.equal(body.has("authed"), false);
});

test("v2.9 роли: teacher не отваря администрацията (UX), реалната защита е RLS/RPC", async () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; isAdmin = false; globalThis.__shown = []; const _s = showScreen; showScreen = id => { __shown.push(id); _s(id); };`);
    t.run(`showAdminScreen("settings"); showAdminScreen("users"); showAdminScreen();`);
    assert.deepEqual([...t.run("__shown")], [], "teacher не получава adminScreen");
    // и записът на настройки/четенето на потребителите минава през RPC с проверка is_admin на сървъра
    const calls = [];
    t.run(`sb = { rpc: async (n, a) => { globalThis.__rpc = (globalThis.__rpc || []).concat([[n, a]]); return { data: null, error: { message: "Само администратор", code: "CS001" } }; } }`);
    await assert.rejects(() => t.run(`storage.saveSettings(${JSON.stringify(SETTINGS)})`));
    assert.equal(t.run("__rpc")[0][0], "admin_update_school_settings");
    await t.run(`storage.loadUsers()`);                                   // сървърен отказ -> няма данни, без изключение
    assert.equal(t.run("storage.getUsers()"), null);
});

test("v2.9 мобилно меню: hamburger отваря/затваря; избор в менюто и Escape затварят", () => {
    const t = setup();
    const body = new Set();
    t.run("document.body").classList = { add() {}, remove() {}, contains: c => body.has(c), toggle(c, on) { on ? body.add(c) : body.delete(c); } };
    t.run("toggleSidebar()");  assert.equal(body.has("sidebar-open"), true);
    t.run("toggleSidebar()");  assert.equal(body.has("sidebar-open"), false);
    t.run("toggleSidebar()");  t.run("showTeacherScreen()");                         // избор в менюто -> затваря
    assert.equal(body.has("sidebar-open"), false);
    t.run("toggleSidebar()");  t.run("showMyConsultations()");  assert.equal(body.has("sidebar-open"), false);
    t.run("closeMyConsultations()");
    t.run("toggleSidebar()");
    t.listeners.keydown.forEach(fn => fn({ key: "Escape" }));
    assert.equal(body.has("sidebar-open"), false);
    // aria
    assert.match(html9(), /id="menuToggle"[^>]*aria-controls="sidebar"[^>]*aria-expanded="false"/);
});

test("v2.9 responsive CSS: sidebar постоянен на desktop, зад hamburger под 900px; без градиенти/анимации", () => {
    const css = css9();
    assert.match(css, /\.sidebar \{[^}]*width: 236px/);                       // 220–250px
    assert.match(css, /@media \(max-width: 900px\)[\s\S]*body\.authed \.menu-toggle \{ display: inline-flex/);
    assert.match(css, /body\.authed \.sidebar \{[^}]*transform: translateX\(-102%\)/);
    assert.match(css, /body\.sidebar-open \.sidebar \{ transform: none/);
    assert.match(css, /\.container \{[^}]*min-width: 0/);                     // основното съдържание се свива без да счупи страницата
    assert.doesNotMatch(css, /gradient|animation|@keyframes|transition/);
});

test("v2.9 настройки: валидация преди запис, RPC с параметри, заглавната лента се обновява", async () => {
    const t = setup();
    t.run(`sb = { rpc: async (n, a) => { (globalThis.__rpc = globalThis.__rpc || []).push([n, a]); return { data: { school_name: a.p_school_name, academic_year: a.p_academic_year, current_term: a.p_current_term }, error: null }; } }`);
    const set = (n, y, term) => t.run(`document.getElementById("settingsSchoolName").value = ${JSON.stringify(n)}; document.getElementById("settingsYear").value = ${JSON.stringify(y)}; document.getElementById("settingsTerm").value = ${JSON.stringify(term)};`);
    set("", "2026/2027", "I");
    await t.run("saveSchoolSettings()");
    assert.equal(t.run("globalThis.__rpc"), undefined, "без име – няма заявка");
    assert.match(t.elements.adminStatus.textContent, /име на училището/);
    set("Тест", "2026/2028", "I");
    await t.run("saveSchoolSettings()");
    assert.equal(t.run("globalThis.__rpc"), undefined);
    assert.match(t.elements.adminStatus.textContent, /последователни години/);
    set("  Ново училище ", "2027/2028", "II");
    await t.run("saveSchoolSettings()");
    const [name, args] = t.run("__rpc")[0];
    assert.equal(name, "admin_update_school_settings");
    assert.deepEqual({ ...args }, { p_school_name: "Ново училище", p_academic_year: "2027/2028", p_current_term: "II" });
    assert.equal(t.elements.headerSchool.textContent, "Ново училище");
    assert.equal(t.elements.headerTerm.textContent, "II срок · 2027/2028");
    assert.match(t.elements.adminStatus.textContent, /запазени/);
});

test("v2.9 смяна на парола: валидация, повторна проверка на текущата, после updateUser; полетата се чистят; паролите не се логват", async () => {
    const t = setup();
    const logs = [];
    t.ctx.console = { log: (...a) => logs.push(a), error: (...a) => logs.push(a), warn: (...a) => logs.push(a) };
    t.run(`currentUser = {id:"u-me", name:"Мария", role:"admin", email:"maria@paisii.info"}; isAdmin = true;
           globalThis.__calls = []; sb = { auth: {
             signInWithPassword: async a => { __calls.push(["signIn", a.email]); return { error: a.password === "Old12345" ? null : { message: "Invalid login credentials" } }; },
             updateUser: async a => { __calls.push(["update"]); return { error: null }; } } };`);
    const fill = (c, n, r) => t.run(`pwCurrent.value=${JSON.stringify(c)}; pwNew.value=${JSON.stringify(n)}; pwRepeat.value=${JSON.stringify(r)};`.replace(/pw(Current|New|Repeat)\.value/g, m => `document.getElementById("${m.slice(0, -6)}").value`));
    fill("", "", ""); await t.run("changePassword()");
    assert.deepEqual([...t.run("__calls")], []); assert.match(t.elements.passwordMessage.textContent, /текущата парола/);
    fill("Old12345", "weakpass", "weakpass"); await t.run("changePassword()");
    assert.deepEqual([...t.run("__calls")], []); assert.match(t.elements.passwordMessage.textContent, /главна буква/);
    fill("Old12345", "Newpass12", "Newpass13"); await t.run("changePassword()");
    assert.deepEqual([...t.run("__calls")], []); assert.match(t.elements.passwordMessage.textContent, /не съвпадат/);
    fill("Wrong1234", "Newpass12", "Newpass12"); await t.run("changePassword()");        // грешна текуща
    assert.deepEqual(t.run("__calls").map(c => c[0]), ["signIn"]); assert.match(t.elements.passwordMessage.textContent, /Текущата парола е грешна/);
    t.run("__calls.length = 0");
    fill("Old12345", "Newpass12", "Newpass12"); await t.run("changePassword()");        // успех
    assert.deepEqual(t.run("__calls").map(c => c[0]), ["signIn", "update"]);
    assert.equal(t.run("__calls")[0][1], "maria@paisii.info");
    assert.match(t.elements.passwordMessage.textContent, /сменена успешно/);
    for (const id of ["pwCurrent", "pwNew", "pwRepeat"]) assert.equal(t.elements[id].value, "");
    assert.ok(!JSON.stringify(logs).match(/Old12345|Newpass12|Wrong1234/), "паролите не са в логовете");
});

test("v2.9 регистрация: само @paisii.info; повторение на паролата; нормализиране; сървърен отказ", async () => {
    const t = setup();
    t.run(`globalThis.__su = []; sb = { auth: { signUp: async a => { __su.push(a); return { data: { session: null }, error: null }; } } }; authMode = "register";`);
    const fill = (name, email, pw, pw2) => t.run(`document.getElementById("regName").value=${JSON.stringify(name)}; document.getElementById("authEmail").value=${JSON.stringify(email)}; document.getElementById("authPassword").value=${JSON.stringify(pw)}; document.getElementById("regPassword2").value=${JSON.stringify(pw2)};`);
    for (const bad of ["ivan@gmail.com", "ivan@abv.bg", "ivan@yahoo.com", "ivan@outlook.com"]) {
        fill("Иван Иванов", bad, "Abcdef12", "Abcdef12"); await t.run("submitAuth()");
        assert.equal(t.run("__su.length"), 0, bad + " не стига до Supabase");
        assert.match(t.elements.authMessage.textContent, /@paisii\.info/);
    }
    fill("Иван Иванов", "ivan@paisii.info", "Abcdef12", "Abcdef13"); await t.run("submitAuth()");
    assert.equal(t.run("__su.length"), 0); assert.match(t.elements.authMessage.textContent, /не съвпадат/);
    fill("Иван Иванов", "ivan@paisii.info", "abcdefgh", "abcdefgh"); await t.run("submitAuth()");
    assert.equal(t.run("__su.length"), 0);
    fill(" Иван Иванов ", "  IVAN@Paisii.INFO ", "Abcdef12", "Abcdef12"); await t.run("submitAuth()");
    assert.equal(t.run("__su.length"), 1);
    assert.equal(t.run("__su[0].email"), "ivan@paisii.info");
    assert.equal(t.run("__su[0].options.data.name"), "Иван Иванов");
    // сървърът (trigger) отказва -> ясно съобщение
    t.run(`authMode = "register"; sb.auth.signUp = async () => ({ data: null, error: { message: "Database error saving new user" } });`);
    fill("Иван Иванов", "ivan@paisii.info", "Abcdef12", "Abcdef12"); await t.run("submitAuth()");
    assert.match(t.elements.authMessage.textContent, /само с имейл от домейна @paisii\.info/);
    // формата има „Повтори паролата“
    assert.match(html9(), /id="regPassword2"[^>]*type="password"|type="password"[^>]*id="regPassword2"|<input id="regPassword2" type="password"/);
});

test("v2.9 вход: съществуващи акаунти с други домейни не се блокират от клиента", async () => {
    const t = setup();
    t.run(`globalThis.__si = []; sb = { auth: { signInWithPassword: async a => { __si.push(a); return { error: null }; } } }; authMode = "login";
           document.getElementById("authEmail").value = " Old.User@Gmail.com "; document.getElementById("authPassword").value = "x";`);
    await t.run("submitAuth()");
    assert.equal(t.run("__si.length"), 1);
    assert.equal(t.run("__si[0].email"), "old.user@gmail.com");
});

test("v2.9 профил: име, имейл, роля; ролята не може да се променя оттук", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Георги Иванов", role:"teacher", email:"georgi@paisii.info"}; showProfileScreen("profile");`);
    assert.equal(t.elements.profileName.textContent, "Георги Иванов");
    assert.equal(t.elements.profileEmail.textContent, "georgi@paisii.info");
    assert.equal(t.elements.profileRole.textContent, "Учител");
    const section = html9().match(/<div id="profileSection"[\s\S]*?<\/div>\s*<div id="passwordSection"/)[0];
    assert.doesNotMatch(section, /<select|<input/);                          // няма контроли за роля
    assert.match(html9(), /onclick="showProfileScreen\('password'\)"/);
});

test("v2.9 администрация → Потребители: име, имейл, роля, статус, дата; без имейл – „—“", () => {
    const t = setup();
    t.run(`storage._users = [{id:"u-t", name:"Учител", email:"georgi@paisii.info", role:"teacher", status:"active", created_at:"2026-09-03T08:00:00Z"},
                             {id:"u-admin", name:"Админ", email:"maria@paisii.info", role:"admin", status:"pending", created_at:"2026-10-01T08:00:00Z"}]; renderTeachersAdmin();`);
    const h = t.elements.teachersAdmin.innerHTML;
    for (const x of ["Име", "Имейл", "Роля", "Статус", "Регистриран", "georgi@paisii.info", "maria@paisii.info", "Активен", "Непотвърден имейл"]) assert.ok(h.includes(x), x);
    t.run(`storage._users = null; renderTeachersAdmin();`);
    assert.match(t.elements.teachersAdmin.innerHTML, /<td class="cell-email">—<\/td>/);
});

test("v2.9 администрация: Настройки/Потребители/Класове/Консултации са отделни секции, всички със запазени функции", () => {
    const html = html9();
    for (const sec of ["settings", "users", "classes", "consultations"]) assert.ok(html.includes(`data-admin-section="${sec}"`), sec);
    const t = setup();
    t.run(`showAdminScreen("classes")`);
    assert.equal(t.run("adminSection"), "classes");
    assert.match(t.elements.adminSectionTitle.textContent, /Администрация · Класове/);
    assert.match(t.elements.classesAdmin.innerHTML, /Прогимназиален/);        // изгледът за класове е непроменен
    t.run(`showAdminScreen("consultations")`);
    assert.ok(t.elements.adminTable.innerHTML.length > 0);
    // етапите 5-7 / 8-12 за класовете са непроменени
    assert.equal(t.run(`stageOfClass("7В")`), "progymnasium");
    assert.equal(t.run(`stageOfClass("8А")`), "gymnasium");
});

test("v2.9: бизнес правилата са непроменени (свободна смяна, слот day+shift+hour, часове по смяна, без правило от 0009 във фронтенда)", () => {
    const t = setup();
    assert.equal(range(setSchedule(t, "8А", 1))[0], "12:35–13:15");
    assert.equal(range(setSchedule(t, "8А", 2))[0], "07:30–08:10");
    const app = fs.readFileSync(path.join(__dirname, "..", "js", "app.js"), "utf8");
    assert.doesNotMatch(app, /get_consultation_stage_shifts|stage_shifts|regular_shift/);
    assert.doesNotMatch(html9().match(/<select id="shiftSelect"[^>]*>/)[0], /disabled|readonly|hidden/i);
    assert.equal(t.run(`evaluateSelection(storage.getAll(), {day:"Понеделник",shift:2,hour:1,subject:"Математика",teacherId:"u-t",classes:["8А"],groupSubjects:[]}).canSave`), true);
});

/* ===================== v2.9 – завършване ===================== */
test("v2.9 миграции: 20261011 връща свободния избор на смяна (без етап->смяна) и е последната; 20261010 има домейн trigger и RLS", () => {
    const dir = path.join(__dirname, "..", "supabase", "migrations");
    const files = fs.readdirSync(dir).filter(f => f.endsWith(".sql")).sort();
    assert.equal(files[files.length - 1], "20261011000000_free_shift_selection.sql");
    const strip = s => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/--[^\n]*/g, "");
    const m11 = strip(fs.readFileSync(path.join(dir, "20261011000000_free_shift_selection.sql"), "utf8"));
    assert.match(m11, /create or replace function public\._save_consultation\(/);
    assert.doesNotMatch(m11, /consultation_stage_of_class|_get_consultation_stage_shifts|v_expected_shift|v_regular_shift|stage_count/);
    // слотът остава (ден, смяна, час)
    assert.match(m11, /c\.shift = p_shift and c\.hour = p_hour/);
    assert.match(m11, /o\.day = p_day and o\.shift = p_shift and o\.hour = p_hour/);
    // старите миграции не са променяни: 0009 остава (не е редактирана), 0011 я надгражда
    assert.ok(files.includes("20261009000000_stage_consultation_shifts.sql"));
    const m10 = strip(fs.readFileSync(path.join(dir, "20261010000000_school_settings_users_domain.sql"), "utf8"));
    assert.match(m10, /before insert or update of email on auth\.users/);
    assert.match(m10, /enable row level security/);
    assert.match(m10, /revoke insert, update, delete[^;]*on public\.school_settings from authenticated/);
    assert.doesNotMatch(m10 + m11, /service_role/);
    assert.match(fs.readFileSync(path.join(__dirname, "..", "supabase", "tests", "v2_9_checks.sql"), "utf8"), /rollback;/);
});

test("v2.9 мобилно меню: има видим бутон за затваряне, който затваря менюто", () => {
    const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
    assert.match(html, /<button type="button" class="nav-close"[^>]*onclick="closeSidebar\(\)"/);
    const t = setup();
    t.run(`setSidebarOpen(true)`);
    t.run(`closeSidebar()`);
    assert.equal(t.run(`document.body.classList.contains("sidebar-open")`), false);
});
