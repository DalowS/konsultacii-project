/* Приложение "График за консултации" – UI слой (данни: storage.js, вход: auth.js, логика: logic.js). */
"use strict";

const CONFIG = {
    schoolName: "Училище",
    classes: [],   // зареждат се от public.classes
    days: DAY_NAMES,
    // Часовете са в js/logic.js (TIME_SLOTS): 7 позиции на смяна; 12:35 - 13:15 е отделна клетка и в двете смени.
    hours: POSITIONS
};

/* ---- Запазен от v1.7 код: рендериране и модали ---- */
function isGroupSubject(subject) {
    const normalized = normalizeSubject(subject);
    return getGroupSubjects().some(item => normalizeSubject(item) === normalized);
}

function getCellRecords(className, shift, day, hour) {
    return storage.getAll().filter(record =>
        normalizeClasses(record).includes(className) &&
        Number(record.shift) === Number(shift) &&      // I смяна/7 и II смяна/1 са ОТДЕЛНИ клетки –
        record.day === day &&                          // нищо не се оглежда между тях
        Number(record.hour) === Number(hour)
    );
}

function renderSchedule() {
    updateViewIndicator();
    const className = document.getElementById("classSelect").value;
    const shift = Number(document.getElementById("shiftSelect").value);

    document.getElementById("scheduleTitle").textContent =
        `${className} • ${shift === 1 ? "I смяна" : "II смяна"}`;

    const table = document.getElementById("scheduleTable");
    if (!className) {
        table.innerHTML = `<tbody><tr><td style="padding:20px;">Няма класове за този етап.</td></tr></tbody>`;
        return;
    }
    let html = `
        <thead>
            <tr>
                <th>Час</th>
                ${CONFIG.days.map(day => `<th>${day}</th>`).join("")}
            </tr>
        </thead>
        <tbody>
    `;

    CONFIG.hours.forEach(hour => {
        html += `<tr>`;
        html += `<td class="hour-cell">${positionLabel(shift, hour) || (hour + " час")}</td>`;

        CONFIG.days.forEach(day => {
            const records = getCellRecords(className, shift, day, hour);

            if (!records.length) {
                html += `<td class="schedule-cell empty-cell" onclick="openAddModal('${className}', ${shift}, '${day}', ${hour})">+ Добави консултация</td>`;
                return;
            }

            const groupMode =
records.length > 0 &&
records.every(r =>
isGroupSubject(r.subject) &&
normalizeSubject(r.subject) === normalizeSubject(records[0].subject)
);
            const canAddGroup = groupMode && records.length < 2;

            html += `<td class="schedule-cell">`;
            html += records.map(record => {
                const own = !!currentUser && record.teacherId === currentUser.id;
                return `
                    <div class="consultation ${own ? "own-record" : "other-record"}">
                        <strong>${escapeHtml(record.subject)}</strong>
                        <div class="teacher">${escapeHtml(record.teacher)}</div>
                        ${record.location ? `<div class="location">📍 ${escapeHtml(record.location)}</div>` : ""}
                        ${groupMode ? `<div class="group-badge">👥 Група</div>` : `<div class="lock">🔒 Заето</div>`}
                        ${own ? `
                            <div class="cell-actions">
                                <button class="btn-secondary" onclick="editConsultation('${record.id}')">Редакция</button>
                                <button class="btn-danger" onclick="deleteOwnConsultation('${record.id}')">Изтрий</button>
                            </div>` : ""}
                    </div>`;
            }).join("");

            if (canAddGroup) {
                html += `<div class="group-add-slot" onclick="openAddModal('${className}', ${shift}, '${day}', ${hour})">+ Добави втора група</div>`;
            }
            html += `</td>`;
        });
        html += `</tr>`;
    });

    html += `</tbody>`;
    table.innerHTML = html;
}

function openAddModal(className, shift, day, hour) {
    const records = getCellRecords(className, shift, day, hour);

    if (records.length > 0) {
        const firstRecord = records[0];

        const allowGroups = isGroupSubject(firstRecord.subject);
 
        if (!allowGroups || records.length >= 2) {
            alert(`Тази клетка вече е заета от ${firstRecord.teacher}.`);
            return;
        }
    }

    document.getElementById("modalTitle").textContent =
        "Добавяне на консултация";

    document.getElementById("modalClass").value = className;
    document.getElementById("modalDay").value = day;
    setModalSlot(shift, hour);
    document.getElementById("modalSubject").value = "";
    document.getElementById("modalLocation").value = "";
    buildExtraClasses();
    document.querySelectorAll(".extraClass").forEach(c=>c.checked=(c.value===className));
    document.getElementById("modalId").value = "";

    openModalOverlay();

    setTimeout(() => {
        document.getElementById("modalSubject").focus();
    }, 100);
}

function editConsultation(id) {
    const record = storage.getAll().find(r => r.id === id);

    if (!record) return;

    if ((!currentUser || record.teacherId !== currentUser.id) && !isAdmin) {
        alert("Нямате право да редактирате този запис.");
        return;
    }

    document.getElementById("modalTitle").textContent =
        "Редактиране на консултация";

    document.getElementById("modalClass").value = primaryClassForStage(record);
    document.getElementById("modalDay").value = record.day;
    setModalSlot(record.shift, record.hour);
    document.getElementById("modalSubject").value = record.subject || "";
    document.getElementById("modalLocation").value = record.location || "";
    buildExtraClasses();
    const cls=normalizeClasses(record);
    document.querySelectorAll(".extraClass").forEach(c=>c.checked=cls.includes(c.value));
    document.getElementById("modalId").value = record.id;

    openModalOverlay();

    setTimeout(() => {
        document.getElementById("modalSubject").focus();
    }, 100);
}

function closeModal() {
    document.getElementById("modalOverlay").style.display = "none";
    adminEditingId = "";
    restoreFocus();
}

function populateAdminFilters() {
    const select = document.getElementById("adminClassFilter");

    if (!select) return;

    const current = select.value;

    select.innerHTML = `<option value="">Всички класове</option>`;

    stageClasses().forEach(className => {
        const option = document.createElement("option");
        option.value = className;
        option.textContent = className;
        select.appendChild(option);
    });

    select.value = current;
}

function renderAdminStats() {
    const records = scopedRecords();
    const teachers = [...new Set(records.map(r => r.teacher).filter(Boolean))];
    const label = document.getElementById("adminStageLabel");
    if (label) label.textContent = STAGES[currentStage].label;

    document.getElementById("adminStats").innerHTML = `
        <div class="admin-stat">
            <span>Класове</span>
            <strong>${stageClasses().length}</strong>
        </div>
        <div class="admin-stat">
            <span>Общо консултации</span>
            <strong>${records.length}</strong>
        </div>
        <div class="admin-stat">
            <span>Учители</span>
            <strong>${teachers.length}</strong>
        </div>
        <div class="admin-stat">
            <span>Заети клетки</span>
            <strong>${countOccupiedCells(records)}</strong>
        </div>
    `;
}

function renderAdminTable() {
    const table = document.getElementById("adminTable");
    if (!table) return;
    const stageLabel = document.getElementById("adminTableStage");
    if (stageLabel) stageLabel.textContent = STAGES[currentStage].label;

    const classFilter = document.getElementById("adminClassFilter")?.value || "";
    const shiftFilter = document.getElementById("adminShiftFilter")?.value || "";
    const teacherFilter = (document.getElementById("adminTeacherFilter")?.value || "")
        .trim()
        .toLowerCase();

    let records = scopedRecords().filter(record => {
        const classOK = !classFilter || normalizeClasses(record).includes(classFilter);
        const shiftOK = !shiftFilter || String(record.shift) === shiftFilter;
        const teacherOK = !teacherFilter ||
            record.teacher.toLowerCase().includes(teacherFilter);

        return classOK && shiftOK && teacherOK;
    });

    records.sort((a, b) => {
        const classCompare = a.className.localeCompare(b.className, "bg");
        if (classCompare !== 0) return classCompare;

        if (a.shift !== b.shift) return a.shift - b.shift;

        const dayCompare =
            CONFIG.days.indexOf(a.day) - CONFIG.days.indexOf(b.day);

        if (dayCompare !== 0) return dayCompare;

        return a.hour - b.hour;
    });

    let html = `
        <thead>
            <tr>
                <th>Класове</th>
                <th>Смяна</th>
                <th>Ден</th>
                <th>Час</th>
                <th>Предмет</th>
                <th>Място</th>
                <th>Учител</th>
                <th>Действия</th>
            </tr>
        </thead>
        <tbody>
    `;

    if (records.length === 0) {
        html += `
            <tr>
                <td colspan="8" style="padding:20px;">
                    Няма записи според избраните филтри.
                </td>
            </tr>
        `;
    }

    records.forEach(record => {
        html += `
            <tr>
                <td>${escapeHtml(normalizeClasses(record).join(", "))}</td>
                <td>${shiftText(record.shift)}</td>
                <td>${escapeHtml(record.day)}</td>
                <td>${escapeHtml(hourLabel(record))}</td>
                <td><strong>${escapeHtml(record.subject)}</strong></td>
                <td>${escapeHtml(record.location || "")}</td>
                <td>${escapeHtml(record.teacher)}</td>
                <td>
                    <button class="btn-secondary"
                            onclick="adminEdit('${record.id}')">
                        Редакция
                    </button>
                    <button class="btn-danger"
                            onclick="adminDelete('${record.id}')">
                        Изтрий
                    </button>
                </td>
            </tr>
        `;
    });

    html += `</tbody>`;
    table.innerHTML = html;
}

function adminEdit(id) {
    const record = storage.getAll().find(r => r.id === id);

    if (!record) {
        alert("Записът не е намерен.");
        return;
    }

    adminEditingId = id;

    document.getElementById("modalTitle").textContent =
        "Администраторска редакция";

    document.getElementById("modalClass").value = primaryClassForStage(record);
    document.getElementById("modalDay").value = record.day;
    setModalSlot(record.shift, record.hour);
    document.getElementById("modalSubject").value = record.subject || "";
    document.getElementById("modalLocation").value = record.location || "";
    buildExtraClasses();
    const cls=normalizeClasses(record);
    document.querySelectorAll(".extraClass").forEach(c=>c.checked=cls.includes(c.value));
    document.getElementById("modalId").value = record.id;

    openModalOverlay();

    setTimeout(() => {
        document.getElementById("modalSubject").focus();
    }, 50);
}

function showAdminStatus(message, type) {
    const element = document.getElementById("adminStatus");

    if (!element) return;

    element.textContent = message;
    element.className = "status " + type;

    setTimeout(() => {
        element.className = "status";
    }, 3500);
}

function showStatus(message, type) {
    const element = document.getElementById("statusMessage");

    element.textContent = message;
    element.className = "status " + type;

    setTimeout(() => {
        element.className = "status";
    }, 3500);
}


/*
    ==========================================================
    STATE (isAdmin / currentUser / currentTeacher са в auth.js)
    ==========================================================
*/
let adminEditingId = "";
let viewNote = "";                       // съобщение след автоматично обръщане на смяната
let viewNoteTimer = null;
let lastFocused = null;                  // къде да се върне фокусът след затваряне на прозорец
let currentStage = DEFAULT_STAGE;        // един списък класове/консултации, филтрира се само изгледът
const STAGE_PREF_KEY = "grafik.stage";   // предпочитание на интерфейса (не данни)
let saving = false;
let realtimeChannel = null;
let pollTimer = null;
let reloadTimer = null;
let authMode = "login";
let sessionQueue = Promise.resolve();

/*
    ==========================================================
    UI ПОМОЩНИ ФУНКЦИИ
    ==========================================================
*/
const SCREENS = ["loadingScreen", "loginScreen", "teacherScreen", "adminScreen"];

function showScreen(id) {
    SCREENS.forEach(s => document.getElementById(s).classList.toggle("hidden", s !== id));
}

function isVisible(id) {
    return !document.getElementById(id).classList.contains("hidden");
}

function notify(message, type) {
    if (isVisible("adminScreen")) showAdminStatus(message, type);
    else showStatus(message, type);
}

function showError(error, fallback) {
    console.error(error);
    notify(friendlyError(error, fallback), "error");
}

function showAuthMessage(message, type) {
    const el = document.getElementById("authMessage");
    el.textContent = message;
    el.className = "status " + (type || "error");
}

function setBusy(button, busy, busyText) {
    if (!button) return;
    if (busy) { button.dataset.label = button.textContent; button.textContent = busyText; }
    else if (button.dataset.label) { button.textContent = button.dataset.label; }
    button.disabled = busy;
}

/*
    ==========================================================
    INITIALIZATION + SESSION
    ==========================================================
*/
document.addEventListener("DOMContentLoaded", async () => {
    if (configError) {
        showScreen("loginScreen");
        showAuthMessage(configError, "error");
        document.getElementById("authSubmit").disabled = true;
        return;
    }

    // Не правим await на Supabase заявки директно в callback-а (известен deadlock) – отлагаме.
    sb.auth.onAuthStateChange((event, session) => {
        setTimeout(() => queueSession(session), 0);
    });

    try {
        queueSession(await auth.getSession());
    } catch (error) {
        showError(error, "Няма връзка със сървъра.");
        showScreen("loginScreen");
        showAuthMessage(friendlyError(error, "Няма връзка със сървъра."), "error");
    }

    window.addEventListener("offline", () => notify("Няма връзка със сървъра.", "error"));
    window.addEventListener("online", () => reloadData());
    document.addEventListener("visibilitychange", () => {
        if (!document.hidden && currentUser) reloadData();
    });
});

function queueSession(session) {
    sessionQueue = sessionQueue.then(() => handleSession(session)).catch(console.error);
}

async function handleSession(session) {
    if (!session) {
        teardown();
        showScreen("loginScreen");
        return;
    }
    if (currentUser && currentUser.id === session.user.id) return;   // дублиран SIGNED_IN при връщане във фокус

    showScreen("loadingScreen");
    try {
        const profile = await auth.loadProfile(session.user);
        await storage.refresh();
        currentUser = profile;
        isAdmin = profile.role === "admin";
        currentTeacher = profile.name;
        CONFIG.classes = storage.getClassNames();
        loadStagePreference();
        populateClasses();
        startRealtime();
        showTeacherScreen();
    } catch (error) {
        console.error(error);
        teardown();
        showScreen("loginScreen");
        showAuthMessage(friendlyError(error, "Неуспешно зареждане на профила. Моля, опитайте отново."), "error");
        sb.auth.signOut();
    }
}

function teardown() {
    stopRealtime();
    currentUser = null;
    isAdmin = false;
    currentTeacher = "";
    storage._cache = [];
    document.getElementById("headerUser").textContent = "";
    document.getElementById("authPassword").value = "";
}

/*
    ==========================================================
    LOGIN / REGISTRATION / LOGOUT
    ==========================================================
*/
function toggleAuthMode() {
    authMode = authMode === "login" ? "register" : "login";
    const reg = authMode === "register";
    document.getElementById("authTitle").textContent = reg ? "Регистрация на учител" : "Вход в системата";
    document.getElementById("authHint").textContent = reg
        ? "Създайте профил с имейл и парола (поне 8 символа)."
        : "Влезте с имейл и парола.";
    document.getElementById("regNameGroup").style.display = reg ? "block" : "none";
    document.getElementById("authSubmit").textContent = reg ? "Регистрация" : "Вход";
    document.getElementById("authToggle").textContent = reg ? "Вече имам профил" : "Нова регистрация";
    document.getElementById("authPassword").autocomplete = reg ? "new-password" : "current-password";
    document.getElementById("authMessage").className = "status";
}

async function submitAuth() {
    const btn = document.getElementById("authSubmit");
    if (btn.disabled) return;
    const email = document.getElementById("authEmail").value.trim();
    const password = document.getElementById("authPassword").value;
    const name = document.getElementById("regName").value.trim();

    if (!email || !password) { showAuthMessage("Моля, въведете имейл и парола.", "error"); return; }
    if (authMode === "register") {
        if (!name) { showAuthMessage("Моля, въведете име и фамилия.", "error"); return; }
        if (password.length < 8) { showAuthMessage("Паролата трябва да е поне 8 символа.", "error"); return; }
    }

    setBusy(btn, true, authMode === "register" ? "Регистриране..." : "Влизане...");
    try {
        if (authMode === "register") {
            const data = await auth.signUp(name, email, password);
            if (!data.session) {
                showAuthMessage("Регистрацията е приета. Проверете имейла си за потвърждение и после влезте.", "success");
                toggleAuthMode();
                document.getElementById("authMessage").className = "status success";
                document.getElementById("authMessage").textContent =
                    "Регистрацията е приета. Проверете имейла си за потвърждение и после влезте.";
            }
        } else {
            await auth.signIn(email, password);     // onAuthStateChange поема от тук
        }
    } catch (error) {
        console.error(error);
        const invalid = /invalid login credentials/i.test(error.message || "");
        showAuthMessage(invalid ? "Грешен имейл или парола."
            : friendlyError(error, "Неуспешен вход. Моля, опитайте отново."), "error");
    } finally {
        setBusy(btn, false);
    }
}

async function logout() {
    try { await auth.signOut(); } catch (error) { console.error(error); }
    teardown();
    showScreen("loginScreen");
}

/*
    ==========================================================
    ЕКРАНИ
    ==========================================================
*/
function showTeacherScreen() {
    showScreen("teacherScreen");
    renderStageTabs();
    document.getElementById("currentTeacher").textContent = currentTeacher;
    document.getElementById("headerUser").textContent =
        currentTeacher + (isAdmin ? " • Администратор" : "");
    document.getElementById("adminToolbarBlock").classList.toggle("hidden", !isAdmin);
    renderSchedule();
}

function showAdminScreen() {
    if (!isAdmin) return;               // само UX; реалната защита е RLS/RPC
    showScreen("adminScreen");
    renderStageTabs();
    populateAdminFilters();
    renderGroupSubjects();
    renderTeachersAdmin();
    renderClassesAdmin();
    refreshAdmin();
}

/*
    ==========================================================
    REALTIME (+ fallback към периодично презареждане)
    ==========================================================
*/
function startRealtime() {
    stopRealtime();
    realtimeChannel = sb.channel("schedule-sync");
    ["consultations", "consultation_classes", "group_subjects", "classes", "teachers"].forEach(table => {
        realtimeChannel.on("postgres_changes", { event: "*", schema: "public", table }, scheduleReload);
    });
    realtimeChannel.subscribe(status => {
        if (status === "SUBSCRIBED") stopPoll();
        else if (["CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)) startPoll();
    });
}

function stopRealtime() {
    clearTimeout(reloadTimer);
    stopPoll();
    if (realtimeChannel) { sb.removeChannel(realtimeChannel); realtimeChannel = null; }
}

function startPoll() {
    if (!pollTimer) pollTimer = setInterval(reloadData, 30000);
}

function stopPoll() {
    clearInterval(pollTimer);
    pollTimer = null;
}

// Събира серия събития (insert в consultations + consultation_classes) в едно презареждане.
function scheduleReload() {
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(reloadData, 400);
}

async function reloadData() {
    if (!currentUser) return;
    try {
        await storage.refresh();
        renderViews();
    } catch (error) {
        console.error(error);
    }
}

function renderViews() {
    if (!currentUser) return;
    const names = storage.getClassNames();
    if (names.join("|") !== CONFIG.classes.join("|")) {
        CONFIG.classes = names;
        populateClasses();
    }
    if (isVisible("teacherScreen")) renderSchedule();
    refreshConflictUI();                                  // новите данни (Realtime) може да променят конфликтите
    if (isMyModalOpen()) renderMyConsultations();
    if (isVisible("adminScreen")) {
        refreshAdmin();
        renderClassesAdmin();
        if (!document.activeElement || !document.activeElement.closest("#teachersAdmin")) renderTeachersAdmin();
        if (!document.activeElement || !document.activeElement.closest("#groupSubjectsContainer")) renderGroupSubjects();
    }
}

/*
    ==========================================================
    ЕТАПИ (гимназиален / прогимназиален) – само филтриране на изгледа
    ==========================================================
*/
function loadStagePreference() {
    try {
        const v = localStorage.getItem(STAGE_PREF_KEY);
        if (STAGE_ORDER.includes(v)) currentStage = v;
    } catch (e) { /* няма достъп до storage – ползваме подразбиране */ }
}

const stageClasses = () => classesOfStage(CONFIG.classes, currentStage);
const scopedRecords = () => scopeRecords(storage.getAll(), currentStage);

// Основен клас при редакция: първият от текущия етап.
function primaryClassForStage(record) {
    return normalizeClasses(record).find(c => stageOfClass(c) === currentStage) || record.className;
}

function renderStageTabs() {
    document.querySelectorAll("[data-stage-tabs]").forEach(box => {
        box.innerHTML = STAGE_ORDER.map(key =>
            `<button type="button" class="stage-tab ${key === currentStage ? "btn-primary" : "btn-secondary"}" ` +
            `aria-pressed="${key === currentStage}" onclick="setStage('${key}')">${escapeHtml(STAGES[key].label)}</button>`
        ).join("");
    });
}

function setStage(stage) {
    if (!STAGE_ORDER.includes(stage) || stage === currentStage) return;
    const shiftSelect = document.getElementById("shiftSelect");
    const previousShift = Number(shiftSelect.value) || 1;
    currentStage = stage;
    try { localStorage.setItem(STAGE_PREF_KEY, stage); } catch (e) { /* не е критично */ }

    // Етапите са в противоположни смени (гимназия I <-> прогимназия II). Обръщаме смяната само
    // при смяна на етапа – не при смяна на клас, филтър и т.н.
    const newShift = getOppositeShift(previousShift);
    shiftSelect.value = String(newShift);

    populateClasses();
    renderStageTabs();
    renderViews();
    setViewNote(`Смяната е сменена автоматично: ${shiftText(previousShift)} → ${shiftText(newShift)} смяна.`);
}

// Ясен индикатор: "Прогимназиален етап · II смяна" (+ бележка след автоматична смяна)
function updateViewIndicator() {
    const el = document.getElementById("viewIndicator");
    if (!el) return;
    const shift = Number(document.getElementById("shiftSelect").value) || 1;
    el.innerHTML = `<strong>${escapeHtml(STAGES[currentStage].label)} · ${shiftText(shift)} смяна</strong>` +
        (viewNote ? `<span class="view-note">${escapeHtml(viewNote)}</span>` : "");
    el.classList.toggle("changed", !!viewNote);
}

function setViewNote(text) {
    viewNote = text;
    clearTimeout(viewNoteTimer);
    updateViewIndicator();
    viewNoteTimer = setTimeout(() => { viewNote = ""; updateViewIndicator(); }, 6000);
    if (viewNoteTimer && viewNoteTimer.unref) viewNoteTimer.unref();
}

/*
    ==========================================================
    КЛАСОВЕ (от базата)
    ==========================================================
*/
function populateClasses() {
    const select = document.getElementById("classSelect");
    const current = select.value;
    select.innerHTML = "";
    stageClasses().forEach(className => {
        const option = document.createElement("option");
        option.value = className;
        option.textContent = className;
        select.appendChild(option);
    });
    if (stageClasses().includes(current)) select.value = current;
}

function buildExtraClasses() {
    const box = document.getElementById("extraClassesBox");
    if (!box) return;
    box.innerHTML = "";
    stageClasses().forEach(c => {
        const lbl = document.createElement("label");
        lbl.innerHTML = `<input type="checkbox" class="extraClass" value="${escapeHtml(c)}"> ${escapeHtml(c)} <span class="class-state" data-class="${escapeHtml(c)}"></span>`;
        lbl.addEventListener("change", refreshConflictUI);
        box.appendChild(lbl);
    });
}

/*
    ==========================================================
    GROUP SUBJECTS (source of truth: public.group_subjects)
    ==========================================================
*/
function getGroupSubjects() {
    return storage.getGroupSubjectRows().filter(r => r.enabled).map(r => r.subject);
}

function renderGroupSubjects() {
    const container = document.getElementById("groupSubjectsContainer");
    if (!container) return;
    const rows = storage.getGroupSubjectRows();
    container.innerHTML = rows.length ? rows.map(r => `
        <label style="display:flex;align-items:center;gap:8px;margin:6px 0;">
            <input type="checkbox" class="groupSubjectCheckbox" data-subject="${escapeHtml(r.subject)}"
                   ${r.enabled ? "checked" : ""}>
            <span>${escapeHtml(r.subject)}</span>
        </label>`).join("") : "<em>Няма предмети.</em>";
}

async function saveGroupSubjects(event) {
    const btn = event && event.currentTarget;
    const boxes = [...document.querySelectorAll(".groupSubjectCheckbox")];
    const changed = boxes.filter(b => {
        const row = storage.getGroupSubjectRows().find(r => r.subject === b.dataset.subject);
        return row && row.enabled !== b.checked;
    });
    if (!changed.length) { showAdminStatus("Няма промени.", "success"); return; }
    setBusy(btn, true, "Записване...");
    try {
        for (const b of changed) await storage.setGroupSubject(b.dataset.subject, b.checked);
        await storage.refresh();
        renderViews();
        showAdminStatus("Настройките са запазени.", "success");
    } catch (error) {
        showError(error, "Неуспешно запазване на настройките.");
    } finally { setBusy(btn, false); }
}

async function addGroupSubject() {
    const input = document.getElementById("newGroupSubject");
    const subject = input.value.trim();
    if (!subject || subject.length > 100) { alert("Въведете предмет (до 100 символа)."); return; }
    try {
        await storage.setGroupSubject(subject, true);
        input.value = "";
        await storage.refresh();
        renderViews();
        showAdminStatus("Предметът е добавен.", "success");
    } catch (error) { showError(error, "Неуспешно добавяне на предмет."); }
}

/*
    ==========================================================
    TEACHERS (admin)
    ==========================================================
*/
function renderTeachersAdmin() {
    const box = document.getElementById("teachersAdmin");
    if (!box) return;
    box.innerHTML = `<thead><tr><th>Име</th><th>Роля</th><th></th></tr></thead><tbody>` +
        storage.getTeachers().map(t => `
        <tr>
            <td><input id="tn_${t.id}" type="text" value="${escapeHtml(t.name)}" maxlength="100"></td>
            <td><select id="tr_${t.id}">
                <option value="teacher" ${t.role === "teacher" ? "selected" : ""}>Учител</option>
                <option value="admin" ${t.role === "admin" ? "selected" : ""}>Администратор</option>
            </select></td>
            <td>
                <button class="btn-primary" onclick="saveTeacher('${t.id}', this)">Запази</button>
                ${currentUser && t.id === currentUser.id
                    ? `<em style="margin-left:8px;color:#64748b;">(Вие)</em>`
                    : `<button class="btn-danger" onclick="removeTeacher('${t.id}', this)">Премахни</button>`}
            </td>
        </tr>`).join("") + `</tbody>`;
}

async function saveTeacher(id, btn) {
    const name = document.getElementById("tn_" + id).value.trim();
    const role = document.getElementById("tr_" + id).value;
    if (!name) { alert("Името не може да е празно."); return; }
    setBusy(btn, true, "Записване...");
    try {
        await storage.updateTeacher(id, { name, role });
        await storage.refresh();
        renderViews();
        showAdminStatus("Потребителят е обновен.", "success");
    } catch (error) {
        showError(error, "Неуспешно обновяване на потребителя.");
    } finally { setBusy(btn, false); }
}

/*
    ==========================================================
    ADD / EDIT / DELETE  (проверката за конфликти е на сървъра)
    ==========================================================
*/
async function saveConsultation() {
    if (saving) return;                     // защита от двоен клик

    const { shift, hour } = modalSlot;
    const day = document.getElementById("modalDay").value;
    const ctx = currentModalParams();
    const { subject, location } = ctx.params;
    const effectiveId = ctx.effectiveId;

    if (!subject) { alert("Моля, въведете предмет."); return; }
    if (!isValidPosition(shift, hour)) { alert("Невалиден час. Този запис е със стара стойност на часа – изтрийте го и го създайте отново."); return; }

    // Бърза проверка върху заредените данни; при частичен конфликт се записват само свободните класове.
    const ev = evaluateSelection(storage.getAll(), ctx.params);
    if (!ev.canSave) {
        refreshConflictUI();
        alert(summarizeSelection(ev).filter(m => m.level !== "ok").map(m => m.text).join("\n"));
        return;
    }
    const classes = ev.free;
    const skipped = ev.blocked;

    const btn = document.getElementById("modalSaveBtn");
    saving = true;
    setBusy(btn, true, "Записване...");
    try {
        const record = { day, shift, hour, subject, location, classes };
        if (effectiveId) await storage.update(effectiveId, record);
        else await storage.add(record);
        closeModal();
        renderViews();
        notify((effectiveId ? "Консултацията е променена." : "Консултацията е добавена и клетката е заключена.") +
            (skipped.length ? ` Не е записана за (конфликт): ${skipped.join(", ")}.` : ""), "success");
    } catch (error) {
        console.error(error);
        alert(friendlyError(error, "Неуспешно записване на консултация. Моля, опитайте отново."));
        if (error && error.code === "CS001") reloadData();     // може някой току-що да е заел клетката
    } finally {
        saving = false;
        setBusy(btn, false);
        refreshConflictUI();
    }
}

async function deleteConsultation(id, details) {
    const record = storage.getAll().find(r => r.id === id);
    if (!record) return;
    if (!confirm(`Да бъде ли изтрит записът?\n\n${details(record)}`)) return;
    try {
        await storage.delete(id);
        renderViews();
        notify("Консултацията е изтрита.", "success");
    } catch (error) {
        showError(error, "Неуспешно изтриване. Моля, опитайте отново.");
        reloadData();
    }
}

function deleteOwnConsultation(id) {
    return deleteConsultation(id, r => `„${r.subject}“ • ${r.day} • ${r.classes.join(", ")}`);
}

function adminDelete(id) {
    return deleteConsultation(id, r =>
        `${r.className} • ${r.day} • ${hourLabel(r)}\n${r.subject} • ${r.teacher}`);
}

/*
    ==========================================================
    ADMIN: clear / backup / restore / import
    ==========================================================
*/
function buildBackup() {
    return {
        version: 2,
        source: "supabase",
        exportedAt: new Date().toISOString(),
        consultations: storage.getAll().map(r => ({
            id: r.id, teacherId: r.teacherId, teacherName: r.teacher,
            day: dayToIndex(r.day), shift: r.shift, hour: r.hour,
            subject: r.subject, location: r.location, classes: r.classes
        })),
        groupSubjects: storage.getGroupSubjectRows().map(r => ({ subject: r.subject, enabled: r.enabled })),
        classes: storage.getClassNames(),
        teachers: storage.getTeachers().map(t => ({ id: t.id, name: t.name, role: t.role }))
    };
}

function downloadFile(filename, content, type) {
    const blob = new Blob([content], { type });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

async function backupData() {
    if (!isAdmin) return;
    try {
        await storage.refresh();
        downloadFile(`grafik-konsultacii-backup-${new Date().toISOString().slice(0, 10)}.json`,
            JSON.stringify(buildBackup(), null, 2), "application/json;charset=utf-8");
    } catch (error) { showError(error, "Неуспешно създаване на резервно копие."); }
}

async function clearAllData() {
    if (!isAdmin) return;
    try { await storage.refresh(); } catch (e) { showError(e, "Няма връзка със сървъра."); return; }
    const count = storage.getAll().length;
    if (count === 0) { alert("Няма записи за изтриване."); return; }

    const confirmation = prompt(
        `Това ще изтрие ЗАВИНАГИ ВСИЧКИ ${count} консултации за ВСИЧКИ учители и за ДВАТА етапа.\n` +
        `Преди това автоматично ще бъде изтеглено резервно копие (JSON).\n\n` +
        `За потвърждение напишете: ИЗТРИЙ`);
    if (confirmation !== "ИЗТРИЙ") { alert("Операцията е отменена."); return; }

    try {
        downloadFile(`grafik-konsultacii-pred-izchistvane-${new Date().toISOString().slice(0, 10)}.json`,
            JSON.stringify(buildBackup(), null, 2), "application/json;charset=utf-8");
        const n = await storage.clear();
        renderViews();
        showAdminStatus(`Изтрити са ${n} консултации.`, "success");
    } catch (error) { showError(error, "Неуспешно изчистване на записите."); }
}

// Старите (v1, localStorage) и новите (v2) записи се привеждат към един формат.
function toImportItem(r) {
    return {
        teacherId: r.teacherId || null,
        teacherName: String(r.teacherName || r.teacher || "").trim(),
        day: typeof r.day === "number" ? r.day : dayToIndex(r.day),
        shift: Number(r.shift),
        hour: Number(r.hour),
        subject: String(r.subject || "").trim(),
        location: String(r.location || "").trim(),
        classes: normalizeClasses(r)
    };
}

function importSummary(res, label) {
    let msg = `${res.imported} консултации ${label} успешно.`;
    if (res.duplicates) msg += ` Пропуснати дубликати: ${res.duplicates}.`;
    if (res.errors && res.errors.length) {
        msg += ` Неуспешни: ${res.errors.length}.`;
        console.warn("Грешки при импорт:", res.errors);
        msg += " " + res.errors.slice(0, 3).map(e => `#${e.index}: ${e.message}`).join(" | ");
    }
    return msg;
}

function restoreData(event) {
    const file = event.target.files && event.target.files[0];
    event.target.value = "";
    if (!file || !isAdmin) return;

    const reader = new FileReader();
    reader.onload = async () => {
        let data;
        try {
            data = JSON.parse(reader.result);
            if (!data || !Array.isArray(data.consultations)) throw new Error("bad");
        } catch (e) { alert("Резервното копие е невалидно или повредено."); return; }

        if (!confirm(`Ще бъдат ЗАМЕНЕНИ текущите ${storage.getAll().length} записи със ${data.consultations.length} от файла.\n` +
                     `Преди това ще бъде изтеглено автоматично копие на текущите данни. Продължаване?`)) return;
        try {
            downloadFile(`grafik-konsultacii-pred-vazstanovyavane-${new Date().toISOString().slice(0, 10)}.json`,
                JSON.stringify(buildBackup(), null, 2), "application/json;charset=utf-8");
            const res = await storage.importItems(data.consultations.map(toImportItem), true);
            if (Array.isArray(data.groupSubjects)) {
                for (const g of data.groupSubjects) {
                    const subject = typeof g === "string" ? g : g.subject;
                    if (subject) await storage.setGroupSubject(subject, typeof g === "string" ? true : g.enabled !== false);
                }
                await storage.refresh();
            }
            renderViews();
            showAdminStatus(importSummary(res, "възстановени"), res.errors && res.errors.length ? "error" : "success");
        } catch (error) { showError(error, "Неуспешно възстановяване на данните."); }
    };
    reader.readAsText(file, "utf-8");
}

// Еднократен инструмент: старите localStorage данни -> Supabase (не се изтриват локално).
async function importLocalData() {
    if (!isAdmin) return;
    let raw;
    try { raw = JSON.parse(localStorage.getItem("consultations")); } catch (e) { raw = null; }
    if (!Array.isArray(raw) || !raw.length) { alert("Няма локални данни от старата версия в този браузър."); return; }
    if (!confirm(`Ще бъдат импортирани ${raw.length} локални консултации в Supabase.\n` +
                 `Учителите се свързват по име – те трябва да са регистрирани със същото име.\n` +
                 `Повторно изпълнение не създава дубликати. Продължаване?`)) return;
    try {
        const res = await storage.importItems(raw.map(toImportItem), false);
        renderViews();
        showAdminStatus(importSummary(res, "импортирани"), res.errors && res.errors.length ? "error" : "success");
    } catch (error) { showError(error, "Неуспешен импорт на локалните данни."); }
}

/*
    ==========================================================
    EXPORT / PRINT / MY CONSULTATIONS
    ==========================================================
*/
function hourLabel(r) {
    return positionLabel(r.shift, r.hour) || `${r.hour} (невалиден час)`;
}

function exportCSV() {
    const stage = STAGES[currentStage];
    const records = scopedRecords();
    if (records.length === 0) { alert(`Няма данни за експортиране (${stage.label}).`); return; }

    const header = ["Учител", "Предмет", "Класове", "Ден", "Смяна", "Час", "Място"];
    const rows = records.map(r => [r.teacher, r.subject, normalizeClasses(r).join(", "),
        r.day, shiftText(r.shift), hourLabel(r), r.location || ""]);
    const csv = [header, ...rows].map(row => row.map(csvCell).join(";")).join("\n");
    downloadFile(`grafik-konsultacii-${stage.file}.csv`, "\uFEFF" + csv, "text/csv;charset=utf-8;");
}

// Оформление на печатния документ: заглавието и таблицата са в един контейнер на цялата
// широчина на печатното поле, затова имат обща хоризонтална ос (заглавието е центрирано
// спрямо страницата И таблицата). Заглавията/колоните на браузъра (header/footer) не са тук.
const PRINT_CSS = `
    @page { margin: 15mm; }
    html, body { margin: 0; padding: 0; }
    .sheet { width: 100%; margin: 0 auto; }
    .sheet h2 { text-align: center; margin: 0 0 16px; }
    .sheet table { width: 100%; border-collapse: collapse; margin: 0 auto; }
    .sheet th, .sheet td { border: 1px solid #000; padding: 6px; }

    /* „Моите консултации“: таблицата започва от левия печатаем край, остава място вдясно,
       колоните се побират (дългите думи се пренасят) – без хоризонтален скрол/изрязване. */
    .sheet-fit { width: calc(100% - 8mm); margin: 0; }
    .sheet-fit table { width: 100%; table-layout: auto; margin: 0; }
    .sheet-fit th, .sheet-fit td { padding: 5px 6px; font-size: 11pt; overflow-wrap: anywhere; }
`;

function writePrintDocument(title, headers, rows, sheetClass = "sheet") {
    const w = window.open("", "_blank");
    if (!w) { alert("Браузърът блокира новия прозорец."); return; }
    const head = headers.map(h => `<th>${escapeHtml(h)}</th>`).join("");
    const body = rows.map(cells => `<tr>${cells.map(c => `<td>${escapeHtml(c)}</td>`).join("")}</tr>`).join("");
    const html = `<html><head><meta charset="utf-8"><title>${escapeHtml(title)}</title><style>${PRINT_CSS}</style></head><body><div class="${sheetClass}"><h2>${escapeHtml(title)}</h2><table><tr>${head}</tr>${body}</table></div></body></html>`;
    w.document.write(html);
    w.document.close();
    w.print();
}

function printScheduleReport() {
    const stage = STAGES[currentStage];
    const records = scopedRecords();
    if (!records.length) { alert(`Няма данни (${stage.label}).`); return; }
    writePrintDocument(`График за консултации – ${stage.label}`,
        ["Учител", "Предмет", "Класове", "Ден", "Смяна", "Час", "Място"],
        records.map(r => [r.teacher, r.subject, r.classes.join(", "), r.day, shiftText(r.shift), hourLabel(r), r.location || ""]));
}

// Печат на ВСИЧКИ консултации на влезлия учител (двата етапа, двете смени)
function printMyConsultations() {
    const records = myRecords();
    if (!records.length) { alert("Нямате консултации за печат."); return; }
    writePrintDocument(`Моите консултации – ${currentUser.name}`,
        ["Етап", "Ден", "Смяна", "Час", "Предмет", "Класове", "Място"],
        records.map(r => [stageNamesOfRecord(r), r.day, shiftText(r.shift), hourLabel(r), r.subject, r.classes.join(", "), r.location || ""]),
        "sheet sheet-fit");
}

// „Моите консултации“ е глобален изглед – не зависи от избрания етап.
const myRecords = () => storage.getAll()
    .filter(r => currentUser && r.teacherId === currentUser.id)
    .sort(compareRecordsByTime);

function isMyModalOpen() { return document.getElementById("myConsultationsModal").style.display === "flex"; }

function renderMyConsultations() {
    const records = myRecords();
    document.getElementById("myConsultationsList").innerHTML = records.length
        ? `<div class="table-scroll"><table class="my-table"><caption class="sr-only">Всички ваши консултации</caption>` +
          `<thead><tr><th scope="col">Етап</th><th scope="col">Ден</th><th scope="col">Смяна</th><th scope="col">Час</th><th scope="col">Предмет</th><th scope="col">Класове</th><th scope="col">Място</th></tr></thead><tbody>` +
          records.map(r => `<tr><td>${escapeHtml(stageNamesOfRecord(r))}</td><td>${escapeHtml(r.day)}</td><td>${shiftText(r.shift)}</td><td>${escapeHtml(hourLabel(r))}</td><td>${escapeHtml(r.subject)}</td><td>${escapeHtml(r.classes.join(", "))}</td><td>${escapeHtml(r.location || "")}</td></tr>`).join("") +
          `</tbody></table></div>`
        : "<p>Нямате консултации.</p>";
    document.getElementById("myPrintBtn").disabled = records.length === 0;
}

function showMyConsultations() {
    lastFocused = document.activeElement;
    renderMyConsultations();
    document.getElementById("myConsultationsModal").style.display = "flex";
}

function closeMyConsultations() {
    document.getElementById("myConsultationsModal").style.display = "none";
    restoreFocus();
}

/*
    ==========================================================
    ФОРМА: проверка за конфликт при попълване (UX) + достъпност
    Сървърът (save_consultation) остава последната защита срещу race condition.
    ==========================================================
*/
function isModalOpen() { return document.getElementById("modalOverlay").style.display === "flex"; }

function openModalOverlay() {
    lastFocused = document.activeElement;
    document.getElementById("modalOverlay").style.display = "flex";
    refreshConflictUI();
}

function restoreFocus() {
    const el = lastFocused;
    lastFocused = null;
    if (el && typeof el.focus === "function") el.focus();
}

// Параметри на проверката от текущото състояние на формата (ден + смяна + час = слот).
function currentModalParams() {
    const effectiveId = adminEditingId || document.getElementById("modalId").value;
    const original = effectiveId ? storage.getAll().find(r => r.id === effectiveId) : null;
    // Класове на другия етап при редакция не се губят (те не се виждат в списъка).
    const outside = original ? normalizeClasses(original).filter(c => stageOfClass(c) !== currentStage) : [];
    const checked = [...document.querySelectorAll(".extraClass:checked")].map(x => x.value);
    return {
        effectiveId, original,
        params: {
            day: document.getElementById("modalDay").value,
            shift: modalSlot.shift,
            hour: modalSlot.hour,
            subject: document.getElementById("modalSubject").value.trim(),
            location: document.getElementById("modalLocation").value.trim(),
            classes: [...new Set([...checked, ...outside])],
            excludeId: effectiveId || "",
            teacherId: original ? original.teacherId : (currentUser && currentUser.id),
            groupSubjects: getGroupSubjects()
        }
    };
}

function conflictItemHtml(d) {
    return `<div class="conflict-item"><p class="conflict-title">${escapeHtml(d.title)}</p><ul>` +
        d.details.map(([k, v]) => `<li>${escapeHtml(k)}: <strong>${escapeHtml(v)}</strong></li>`).join("") + `</ul></div>`;
}

function refreshConflictUI() {
    if (!isModalOpen()) return;
    const records = storage.getAll();
    const { params } = currentModalParams();
    const ev = evaluateSelection(records, params);

    const messages = summarizeSelection(ev);
    const level = messages.some(m => m.level === "error") ? "error" : messages.some(m => m.level === "warn") ? "warn" : "ok";
    const summary = document.getElementById("conflictSummary");
    summary.className = `conflict-summary ${level}`;
    summary.innerHTML = messages.map(m => `<p>${escapeHtml(m.text)}</p>`).join("");

    let details = "";
    if (ev.teacherConflict) {
        const r = ev.teacherConflict;
        details += conflictItemHtml({ title: "⚠️ Учителят вече има консултация в този час.",
            details: [["Предмет", r.subject], ["Класове", r.classes.join(", ")]].concat(r.location ? [["Място", r.location]] : []) });
    }
    ev.blocked.forEach(c => { details += conflictItemHtml(describeClassConflict(c, ev.conflicts[c])); });
    document.getElementById("conflictBox").innerHTML = details;

    const markers = classMarkers(records, params, stageClasses());
    document.querySelectorAll(".class-state").forEach(span => {
        const text = markers[span.dataset.class] || "";
        span.textContent = text;
        span.className = "class-state" + (text.startsWith("⚠") ? " bad" : text ? " good" : "");
    });

    const btn = document.getElementById("modalSaveBtn");
    if (btn && !saving) {
        btn.disabled = !ev.canSave;
        btn.setAttribute("aria-disabled", String(!ev.canSave));
    }
}

// Escape затваря отворения прозорец
document.addEventListener("keydown", event => {
    if (event.key !== "Escape") return;
    if (isModalOpen()) closeModal();
    else if (isMyModalOpen()) closeMyConsultations();
});

/*
    ==========================================================
    HELPERS
    ==========================================================
*/
function refreshAdmin() {
    populateAdminFilters();
    renderAdminTable();
    renderAdminStats();
}

/*
    ==========================================================
    ЧАСОВЕ: контекст на модала + етикети
    ==========================================================
*/
let modalSlot = { shift: 1, hour: 1 };

function setModalSlot(shift, hour) {
    modalSlot = { shift: Number(shift), hour: Number(hour) };
    document.getElementById("modalShift").value = Number(shift) === 1 ? "I смяна" : "II смяна";
    document.getElementById("modalHour").value = positionLabel(shift, hour) || `${hour} (невалиден час)`;
}


/*
    ==========================================================
    КЛАСОВЕ (admin): добавяне / изтриване
    ==========================================================
*/
// Две карти една до друга: Прогимназиален (5-7) вляво, Гимназиален (8-12) вдясно.
// Етапът се определя със същата функция като навсякъде (stageOfClass). Класове извън 5-12
// (ако има такива) се показват в допълнителна карта, за да не изчезват.
const CLASS_CARD_ORDER = ["progymnasium", "gymnasium"];

function renderClassesAdmin() {
    const box = document.getElementById("classesAdmin");
    if (!box) return;
    const used = new Map();
    storage.getAll().forEach(r => r.classes.forEach(c => used.set(c, (used.get(c) || 0) + 1)));

    const row = c => {
        const n = used.get(c.name) || 0;
        return `<tr>
            <td><strong>${escapeHtml(c.name)}</strong></td>
            <td class="num">${n}</td>
            <td class="action">${n
                ? `<span class="class-locked" title="Класът има консултации и не може да се изтрие"><span aria-hidden="true">🔒</span> Има консултации</span>`
                : `<button class="btn-danger btn-compact" onclick="deleteClass('${Number(c.id)}', this)">Изтрий</button>`}</td>
        </tr>`;
    };
    const card = (key, title, list, extra = "") =>
        `<section class="class-card${extra}" data-stage="${key}"><h4>${escapeHtml(title)}</h4>` +
        `<table class="classes-table"><thead><tr><th scope="col">Клас</th><th scope="col">Консултации</th><th scope="col">Действие</th></tr></thead><tbody>` +
        (list.length ? list.map(row).join("") : `<tr><td colspan="3" class="class-empty">Няма класове.</td></tr>`) +
        `</tbody></table></section>`;

    const all = storage.getClasses();
    let html = CLASS_CARD_ORDER.map(key => card(key, STAGES[key].label, all.filter(c => stageOfClass(c.name) === key))).join("");
    const other = all.filter(c => !stageOfClass(c.name));
    if (other.length) html += card("other", "Други класове", other, " class-card-wide");
    box.innerHTML = html;
}

async function addClass(event) {
    const btn = event && event.currentTarget;
    const result = buildClassName(
        document.getElementById("newClassGrade").value,
        document.getElementById("newClassLetter").value);
    if (!result.ok) { alert(result.error); return; }
    if (storage.getClassNames().includes(result.name)) { alert(`Класът ${result.name} вече съществува.`); return; }

    setBusy(btn, true, "Добавяне...");
    try {
        await storage.addClass(result.grade, result.letter);
        document.getElementById("newClassLetter").value = "";
        renderViews();
        showAdminStatus(`Класът ${result.name} е добавен.`, "success");
    } catch (error) {
        showError(error, "Неуспешно добавяне на клас. Моля, опитайте отново.");
    } finally { setBusy(btn, false); }
}

async function deleteClass(id, btn) {
    const cls = storage.getClasses().find(c => String(c.id) === String(id));
    if (!cls) return;
    if (!confirm(`Да бъде ли изтрит класът ${cls.name}?`)) return;
    setBusy(btn, true, "Изтриване...");
    try {
        await storage.deleteClass(id);
        renderViews();
        showAdminStatus(`Класът ${cls.name} е изтрит.`, "success");
    } catch (error) {
        showError(error, "Неуспешно изтриване на клас.");
        reloadData();
    } finally { setBusy(btn, false); }
}

/*
    ==========================================================
    УЧИТЕЛИ (admin): премахване (Auth акаунт + консултации, атомарно на сървъра)
    ==========================================================
*/
async function removeTeacher(id, btn) {
    const teacher = storage.getTeachers().find(t => t.id === id);
    if (!teacher || !currentUser || id === currentUser.id) return;
    const count = storage.getAll().filter(r => r.teacherId === id).length;
    if (!confirm(`Да бъде ли премахнат учителят „${teacher.name}“?\n\n` +
                 `• Акаунтът му ще бъде изтрит и той вече няма да може да влиза.\n` +
                 `• Ще бъдат изтрити и неговите консултации: ${count}.\n\n` +
                 `Операцията е необратима.`)) return;
    setBusy(btn, true, "Премахване...");
    try {
        const res = await storage.deleteTeacher(id);
        renderTeachersAdmin();
        renderViews();
        showAdminStatus(`Учителят „${teacher.name}“ е премахнат. Изтрити консултации: ${res && res.consultations_deleted != null ? res.consultations_deleted : count}.`, "success");
    } catch (error) {
        showError(error, "Неуспешно премахване на учителя. Моля, опитайте отново.");
        reloadData();
    } finally { setBusy(btn, false); }
}
