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
        querySelectorAll: sel => sel === "[data-stage-tabs]" ? [(elements.__tabs ||= mk())] : [],
        createElement: () => mk(), addEventListener() {}, body: mk(), activeElement: null, hidden: false
    };
    const downloads = [], alerts = [], printed = [];
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
    return { ctx, elements, downloads, alerts, printed, run: code => vm.runInContext(code, ctx) };
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
    assert.match(s1[0], /7:30 - 8:10/);   assert.match(s1[6], /12:35 - 13:15/);
    assert.match(s2[0], /12:35 - 13:15/); assert.match(s2[6], /17:50 - 18:30/);
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
    assert.equal(t.elements.modalHour.value, "12:35 - 13:15");
    assert.equal(t.elements.modalShift.value, "II смяна");
    assert.deepEqual(JSON.parse(JSON.stringify(t.run("modalSlot"))), { shift: 2, hour: 1 });
    t.run(`openAddModal("8А", 1, "Петък", 7)`);
    assert.equal(t.elements.modalHour.value, "12:35 - 13:15");
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

test("„Моите консултации“ уважава етапа", () => {
    const t = setup();
    t.run(`currentUser = {id:"u-t", name:"Учител", role:"teacher"}; showMyConsultations();`);
    let h = t.elements.myConsultationsList.innerHTML;
    assert.match(h, /Гимназиален етап/); assert.match(h, /Математика/); assert.doesNotMatch(h, /Англ/);
    t.run(`setStage("progymnasium"); showMyConsultations();`);
    h = t.elements.myConsultationsList.innerHTML;
    assert.match(h, /Англ/); assert.doesNotMatch(h, /Математика/);
});

test("редакция на смесена консултация: извънетапните класове се запазват", () => {
    const t = setup();
    const calls = [];
    t.run(`storage.update = async (id, rec) => { globalThis.__saved = {id, rec}; };`);
    t.run(`setStage("gymnasium"); editConsultation("6");`);          // 7А + 8А, в гимназията се вижда 8А
    assert.equal(t.elements.modalClass.value, "8А");
    t.run(`document.getElementById("modalSubject").value="Смесена"; document.getElementById("modalId").value="6";`);
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
