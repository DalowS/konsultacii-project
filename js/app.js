/* Приложение "График за консултации" – UI слой (данни: storage.js, вход: auth.js, логика: logic.js). */
"use strict";

const CONFIG = {
    schoolName: "Училище",
    classes: [],   // зареждат се от public.classes
    days: DAY_NAMES,
    // v3.0: интервалите са по училище (storage.loadSchedule -> setSchedule в js/logic.js); позициите на смяна: positionsOf(shift).
    hours: POSITIONS
};

// „I смяна“ / „II смяна“ (две смени) или „Единна смяна“ (една смяна)
const shiftName = shift => `${shiftText(shift)} смяна`;

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
        `${className} • ${shiftName(shift)}`;

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

    positionsOf(shift).forEach(hour => {
        html += `<tr>`;
        html += `<td class="hour-cell">${formatTimeRange(positionLabel(shift, hour)) || (hour + " час")}</td>`;

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
                <td>${escapeHtml(shiftText(record.shift))}</td>
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
let adminSection = "consultations";          // settings | users | domains | schedule | classes | consultations
let isSuperAdmin = false;                    // v3.0: глобален супер администратор (само UX; сървърът решава)
let activeSchool = null;                     // {id,name,status} или null (глобален изглед)
let profileSection = "profile";              // profile | password
const ADMIN_TITLES = { settings: "Настройки", users: "Потребители", domains: "Домейни", schedule: "График на часовете", classes: "Класове", consultations: "Консултации" };
let sessionQueue = Promise.resolve();

/*
    ==========================================================
    UI ПОМОЩНИ ФУНКЦИИ
    ==========================================================
*/
const SCREENS = ["loadingScreen", "loginScreen", "blockedScreen", "schoolsScreen", "teacherScreen", "adminScreen", "profileScreen"];

function showScreen(id) {
    SCREENS.forEach(s => document.getElementById(s).classList.toggle("hidden", s !== id));
    // навигацията (sidebar, потребител в заглавната лента) е само след вход
    const inApp = ["teacherScreen", "adminScreen", "profileScreen", "schoolsScreen"].includes(id);
    document.body.classList.toggle("authed", inApp);
    closeSidebar();
    renderHeader();
    updateNav();
}

// Заглавна лента: срок и учебна година + име на училището идват от настройките (БД), не са във HTML.
function renderHeader() {
    const settings = storage.getSettings();
    const set = (id, text) => { const el = document.getElementById(id); if (el) el.textContent = text; };
    set("headerTerm", termLine(settings));
    set("headerSchool", settings ? settings.school_name : (activeSchool ? activeSchool.name : ""));
    set("footerNote", activeSchool || settings
        ? `Сайтът е разработен в помощ на ${(settings && settings.school_name) || activeSchool.name}`
        : "График за консултации");
    // v3.0: винаги видим индикатор за контекста (училище или глобален изглед)
    const ind = document.getElementById("schoolIndicator");
    if (ind) {
        ind.classList.toggle("hidden", !currentUser);
        set("schoolIndicatorName", !currentUser ? "" : activeSchool
            ? `Училище: ${activeSchool.name}${activeSchool.status === "inactive" ? " (неактивно)" : ""}`
            : isSuperAdmin ? "Глобален изглед (няма избрано училище)" : "");
        const back = document.getElementById("schoolBackBtn");
        if (back) back.classList.toggle("hidden", !(isSuperAdmin && activeSchool));
    }
    const superNav = document.getElementById("superNavBlock");
    if (superNav) superNav.classList.toggle("hidden", !isSuperAdmin);
    // в глобален изглед (супер админ без избрано училище) няма график/мои консултации
    document.querySelectorAll('#sidebar [data-nav="schedule"], #sidebar [data-nav="mine"]').forEach(b => b.classList.toggle("hidden", !activeSchool));
    const schedBtn = document.querySelector('#sidebar [data-nav="schedule"]');
    if (schedBtn && schedBtn.closest) { const g = schedBtn.closest(".nav-group"); if (g) g.classList.toggle("hidden", !activeSchool); }
    set("headerUser", currentUser ? userLine(currentTeacher, currentUser.role) : "");
    set("currentTeacher", currentTeacher);
    set("sidebarUser", currentUser ? userLine(currentTeacher, currentUser.role) : "");   // видимо в менюто на малки екрани
    // само UX: администраторските изгледи са защитени от RLS/RPC (is_admin) на сървъра
    const adminNav = document.getElementById("adminToolbarBlock");
    if (adminNav) adminNav.classList.toggle("hidden", !isAdmin);
}

function currentNavKey() {
    if (isVisible("schoolsScreen")) return "schools";
    if (isVisible("teacherScreen")) return "schedule";
    if (isVisible("adminScreen")) return "admin-" + adminSection;
    if (isVisible("profileScreen")) return profileSection;
    return "";
}

function updateNav() {
    const key = currentNavKey();
    document.querySelectorAll("[data-nav]").forEach(btn => {
        if (btn.dataset.nav === key) btn.setAttribute("aria-current", "page");
        else btn.removeAttribute("aria-current");
    });
}

function setSidebarOpen(open) {
    document.body.classList.toggle("sidebar-open", !!open);
    const toggle = document.getElementById("menuToggle");
    if (toggle) toggle.setAttribute("aria-expanded", String(!!open));
}
function toggleSidebar() { setSidebarOpen(!document.body.classList.contains("sidebar-open")); }
function closeSidebar() { setSidebarOpen(false); }

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
    initIcons();

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
        const profile = await auth.loadProfile(session.user);     // сървърът решава роля и училище
        applyProfile(profile);
        if (profile.blocked) {                                     // няма членство / неактивно училище
            showBlockedScreen(profile);
            return;
        }
        if (isSuperAdmin && !activeSchool) {                       // глобален изглед: само управление на училища
            startRealtime();
            await showSchoolsScreen();
            return;
        }
        await loadSchoolData();
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

function applyProfile(profile) {
    currentUser = profile;
    isSuperAdmin = !!profile.is_super_admin;
    isAdmin = !!profile.is_admin;                 // админ на избраното/собственото училище (не важи за глобален изглед)
    currentTeacher = profile.name;
    activeSchool = profile.school || null;
}

// Данни на активното училище: график (интервали), класове, консултации, настройки.
async function loadSchoolData() {
    await storage.loadSchedule(isAdmin);          // не блокира при грешка -> подразбиращ се график
    setSchedule(storage.getSchedule());
    await storage.refresh();
    await storage.loadSettings();
    CONFIG.classes = storage.getClassNames();
    loadStagePreference();
    populateClasses();
    applyScheduleToUI();
}

function showBlockedScreen(profile) {
    const reason = profile.blocked_reason;
    document.getElementById("blockedText").textContent =
        reason === "school_inactive" ? "Вашето училище е неактивно. Обърнете се към администратор на платформата."
        : reason === "no_membership" ? "Профилът Ви не е свързан с училище. Регистрирайте се с имейл от домейн на училището си или поискайте покана."
        : "Нямате достъп до активно училище.";
    showScreen("blockedScreen");
}

// Динамични смени/часове според режима на училището (без заключване на #shiftSelect при две смени).
function applyScheduleToUI() {
    const shifts = activeShifts();
    const fill = (id, withAll) => {
        const el = document.getElementById(id);
        if (!el) return;
        const cur = el.value;
        el.innerHTML = (withAll ? `<option value="">Всички смени</option>` : "") +
            shifts.map(sh => `<option value="${sh}">${escapeHtml(shiftName(sh))}</option>`).join("");
        el.value = shifts.map(String).includes(String(cur)) ? cur : (withAll ? "" : String(shifts[0] || 1));
        const group = el.closest ? el.closest(".form-group") : null;
        if (group) group.classList.toggle("hidden", shifts.length < 2);   // една смяна: няма какво да се избира
    };
    fill("shiftSelect", false);
    fill("adminShiftFilter", true);
}

function teardown() {
    stopRealtime();
    currentUser = null;
    isAdmin = false;
    isSuperAdmin = false;
    activeSchool = null;
    currentTeacher = "";
    storage.resetCache();
    storage._schools = null;
    setSchedule(null);
    closeSchoolDetail();
    ["authPassword", "regPassword2", "pwCurrent", "pwNew", "pwRepeat"].forEach(id => {
        const el = document.getElementById(id); if (el) el.value = "";
    });
    renderHeader();
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
        ? "Регистрация с имейл от разрешен домейн на училището или с покана от администратор. Паролата е поне 8 символа, с главна и малка буква и цифра."
        : "Влезте с имейл и парола.";
    document.getElementById("regNameGroup").style.display = reg ? "block" : "none";
    document.getElementById("regPassword2Group").style.display = reg ? "block" : "none";
    document.getElementById("regPassword2").value = "";
    document.getElementById("authSubmit").textContent = reg ? "Регистрация" : "Вход";
    document.getElementById("authToggle").textContent = reg ? "Вече имам профил" : "Нова регистрация";
    document.getElementById("authPassword").autocomplete = reg ? "new-password" : "current-password";
    document.getElementById("authMessage").className = "status";
}

async function submitAuth() {
    const btn = document.getElementById("authSubmit");
    if (btn.disabled) return;
    const password = document.getElementById("authPassword").value;
    const name = document.getElementById("regName").value.trim();
    let email = normalizeEmail(document.getElementById("authEmail").value);

    if (authMode === "register") {
        // само UX слой (форма); домейнът и училището се определят на сървъра (trigger върху auth.users, миграция 20261012000000)
        const v = validateRegistration({ name, email, password, password2: document.getElementById("regPassword2").value });
        if (!v.ok) { showAuthMessage(v.errors.join("\n"), "error"); return; }
        email = v.email;
    } else if (!email || !password) {
        showAuthMessage("Моля, въведете имейл и парола.", "error"); return;
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
        const dbReject = authMode === "register" && /database error saving new user|домейн|покана/i.test(error.message || "");
        showAuthMessage(invalid ? "Грешен имейл или парола."
            : dbReject ? "Регистрацията не е разрешена за този имейл. Използвайте имейл от домейна на училището си или поискайте покана от администратор."
            : friendlyError(error, authMode === "register" ? "Неуспешна регистрация. Моля, опитайте отново." : "Неуспешен вход. Моля, опитайте отново."), "error");
    } finally {
        setBusy(btn, false);
    }
}


async function logout() {
    try {
        await auth.signOut();
    } catch (error) {
        console.error(error);
    }

    teardown();

    // Връщаме формата в режим „Вход“
    if (authMode !== "login") {
        toggleAuthMode();
    }

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
    renderSchedule();
}

function applyAdminSection() {
    document.querySelectorAll("[data-admin-section]").forEach(el =>
        el.classList.toggle("hidden", el.dataset.adminSection !== adminSection));
    const title = document.getElementById("adminSectionTitle");
    if (title) title.textContent = "Администрация · " + (ADMIN_TITLES[adminSection] || "");
}

function showAdminScreen(section) {
    if (!isAdmin) return;               // само UX; реалната защита е RLS/RPC
    if (ADMIN_TITLES[section]) adminSection = section;
    applyScheduleToUI();
    showScreen("adminScreen");
    applyAdminSection();
    updateNav();
    renderStageTabs();
    populateAdminFilters();
    renderGroupSubjects();
    renderTeachersAdmin();
    renderClassesAdmin();
    refreshAdmin();
    if (adminSection === "settings") fillSettingsForm();
    if (adminSection === "users") loadUsersAndRender();
    if (adminSection === "domains") renderDomains("adm", null);
    if (adminSection === "schedule") renderScheduleAdmin();
}

function fillSettingsForm() {
    const s = storage.getSettings();
    if (!s) {
        showAdminStatus("Настройките на училището не са налични. Приложете миграциите за v2.9 и v3.0 (multi-school).", "error");
        return;
    }
    document.getElementById("settingsSchoolName").value = s.school_name;
    document.getElementById("settingsYear").value = s.academic_year;
    document.getElementById("settingsTerm").value = s.current_term;
}

async function saveSchoolSettings(btn) {
    const v = validateSettings({
        school_name: document.getElementById("settingsSchoolName").value,
        academic_year: document.getElementById("settingsYear").value,
        current_term: document.getElementById("settingsTerm").value
    });
    if (!v.ok) { showAdminStatus(v.errors.join("\n"), "error"); return; }
    btn = btn || document.getElementById("settingsSaveBtn");
    setBusy(btn, true, "Записване...");
    try {
        await storage.saveSettings(v.value);       // RPC admin_update_school_settings (само админ, проверка на сървъра)
        renderHeader();
        fillSettingsForm();
        showAdminStatus("Настройките са запазени.", "success");
    } catch (error) {
        showError(error, "Неуспешно запазване на настройките.");
    } finally { setBusy(btn, false); }
}

async function loadUsersAndRender() {
    if (!isAdmin) return;
    await storage.loadUsers();
    if (isVisible("adminScreen")) renderTeachersAdmin();
}

/*
    ==========================================================
    ПРОФИЛ И СМЯНА НА ПАРОЛА
    ==========================================================
*/
function showProfileScreen(section) {
    if (!currentUser) return;
    profileSection = section === "password" ? "password" : "profile";
    showScreen("profileScreen");
    document.querySelectorAll("[data-profile-section]").forEach(el =>
        el.classList.toggle("hidden", el.dataset.profileSection !== profileSection));
    document.getElementById("profileSectionTitle").textContent = profileSection === "password" ? "Смяна на парола" : "Моят профил";
    document.getElementById("profileName").textContent = currentUser.name || "";
    document.getElementById("profileEmail").textContent = currentUser.email || "";
    document.getElementById("profileRole").textContent = roleLabel(currentUser.role);
    ["pwCurrent", "pwNew", "pwRepeat"].forEach(id => { document.getElementById(id).value = ""; });
    showPasswordMessage("", "");
    updateNav();
}

function showPasswordMessage(message, type) {
    const el = document.getElementById("passwordMessage");
    el.textContent = message;
    el.className = "status" + (type ? " " + type : "");
}

async function changePassword() {
    const btn = document.getElementById("pwSubmit");
    if (btn.disabled || !currentUser) return;
    const current = document.getElementById("pwCurrent").value;
    const next = document.getElementById("pwNew").value;
    const repeat = document.getElementById("pwRepeat").value;

    const v = validatePasswordChange({ current, next, repeat });
    if (!v.ok) { showPasswordMessage(v.errors.join("\n"), "error"); return; }

    setBusy(btn, true, "Сменяне...");
    try {
        await auth.changePassword(currentUser.email, current, next);
        ["pwCurrent", "pwNew", "pwRepeat"].forEach(id => { document.getElementById(id).value = ""; });
        showPasswordMessage("Паролата е сменена успешно.", "success");
    } catch (error) {
        // паролите никога не се логват – само кодът/съобщението на грешката
        console.error("Смяна на парола:", error && (error.code || error.message));
        showPasswordMessage(error && error.code === "WRONG_CURRENT_PASSWORD"
            ? "Текущата парола е грешна."
            : friendlyError(error, "Паролата не можа да бъде сменена. Моля, опитайте отново."), "error");
    } finally { setBusy(btn, false); }
}

/*
    ==========================================================
    REALTIME (+ fallback към периодично презареждане)
    ==========================================================
*/
function startRealtime() {
    stopRealtime();
    realtimeChannel = sb.channel("schedule-sync");
    // v3.0: + настройки/график/училища (миграция 20261015 ги публикува; RLS на сървъра филтрира събитията по училище)
    ["consultations", "consultation_classes", "group_subjects", "classes", "teachers",
     "school_settings", "school_schedule_settings", "school_intervals", "schools"].forEach(table => {
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
        if (!activeSchool) return;                      // глобален изглед: няма данни на училище
        // Роля/училище/статус могат да са се променили на сървъра (деактивирано училище, махнат админ) -> нов вход в контекста
        if (await contextChanged()) {
            const session = await auth.getSession();
            currentUser = null;
            await handleSession(session);
            return;
        }
        await storage.loadSchedule(isAdmin);
        setSchedule(storage.getSchedule());
        applyScheduleToUI();
        await storage.refresh();
        await storage.loadSettings();
        if (isAdmin && isVisible("adminScreen") && adminSection === "users") await storage.loadUsers();
        renderViews();
        renderHeader();
    } catch (error) {
        console.error(error);
    }
}

// Сървърът е източникът на истината за роля/училище; сравняваме, без да вярваме на клиентското състояние.
async function contextChanged() {
    try {
        const p = await auth.loadProfile({ id: currentUser.id, email: currentUser.email });
        return !!p.blocked || !!p.is_super_admin !== isSuperAdmin || !!p.is_admin !== isAdmin ||
            (p.school ? p.school.id : null) !== (activeSchool ? activeSchool.id : null);
    } catch (error) {
        console.error(error);
        return false;                                 // временна грешка: не изхвърляме потребителя
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
    if (newShift !== previousShift) setViewNote(`Смяната е сменена автоматично: ${shiftText(previousShift)} → ${shiftText(newShift)} смяна.`);
}

// Ясен индикатор: "Прогимназиален етап · II смяна" (+ бележка след автоматична смяна)
function updateViewIndicator() {
    const el = document.getElementById("viewIndicator");
    if (!el) return;
    const shift = Number(document.getElementById("shiftSelect").value) || 1;
    el.innerHTML = `<strong>${escapeHtml(STAGES[currentStage].label)} · ${escapeHtml(shiftName(shift))}</strong>` +
        `<span class="view-range">Консултации: <b>${escapeHtml(shiftRangeLabel(shift))}</b></span>` +
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
    // имейл, статус и дата идват от защитена функция (само админ); ако още не е заредена – „—“
    const users = new Map((storage.getUsers() || []).map(u => [u.id, u]));
    const date = v => { const d = v ? new Date(v) : null; return d && !isNaN(d) ? d.toLocaleDateString("bg-BG") : "—"; };
    box.innerHTML = `<thead><tr><th>Име</th><th>Имейл</th><th>Роля</th><th>Статус</th><th>Регистриран</th><th></th></tr></thead><tbody>` +
        storage.getTeachers().map(t => {
            const u = users.get(t.id);
            return `
        <tr>
            <td><input id="tn_${t.id}" type="text" value="${escapeHtml(t.name)}" maxlength="100" aria-label="Име"></td>
            <td class="cell-email">${u ? escapeHtml(u.email || "—") : "—"}</td>
            <td><select id="tr_${t.id}" aria-label="Роля">
                <option value="teacher" ${t.role === "teacher" ? "selected" : ""}>Учител</option>
                <option value="admin" ${t.role === "admin" ? "selected" : ""}>Администратор</option>
            </select></td>
            <td>${escapeHtml(u ? userStatusLabel(u.status) : "—")}</td>
            <td>${u ? date(u.created_at) : "—"}</td>
            <td class="cell-actions-col">
                <button class="btn-primary" onclick="saveTeacher('${t.id}', this)">Запази</button>
                ${currentUser && t.id === currentUser.id
                    ? `<em class="muted">(Вие)</em>`
                    : `<button class="btn-danger" onclick="removeTeacher('${t.id}', this)">Премахни</button>`}
            </td>
        </tr>`; }).join("") + `</tbody>`;
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
function initIcons() {
    if (typeof lucide !== 'undefined') {
        lucide.createIcons();
    }
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
    closeSidebar();
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
    else if (document.body.classList.contains("sidebar-open")) closeSidebar();
});
// при преминаване към голям екран мобилното меню се затваря
window.addEventListener("resize", () => { if (window.innerWidth > 900) closeSidebar(); });

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
    document.getElementById("modalShift").value = shiftName(shift);
    document.getElementById("modalHour").value = formatTimeRange(positionLabel(shift, hour)) || `${hour} (невалиден час)`;
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

/*
    ==========================================================
    v3.0: УЧИЛИЩА (супер администратор), ДОМЕЙНИ, ПОКАНИ, ГРАФИК НА ЧАСОВЕТЕ
    Всичко тук е само интерфейс – правата се проверяват на сървъра (RLS/RPC).
    ==========================================================
*/
function schoolMsg(message, type) {
    const el = document.getElementById("schoolsStatus");
    if (!el) return;
    el.textContent = message;
    el.className = "status " + (type || "");
    setTimeout(() => { el.className = "status"; }, 4500);
}

async function showSchoolsScreen() {
    if (!isSuperAdmin) return;
    showScreen("schoolsScreen");
    try {
        await storage.loadSchools();
        renderSchoolsList();
    } catch (error) {
        console.error(error);
        schoolMsg(friendlyError(error, "Неуспешно зареждане на училищата."), "error");
    }
}

function renderSchoolsList() {
    const table = document.getElementById("schoolsTable");
    if (!table) return;
    const q = (document.getElementById("schoolSearch").value || "").trim().toLowerCase();
    const st = document.getElementById("schoolStatusFilter").value;
    const rows = (storage.getSchools() || []).filter(sc =>
        (!st || sc.status === st) &&
        (!q || sc.name.toLowerCase().includes(q) || (sc.domains || []).some(d => d.toLowerCase().includes(q))));
    table.innerHTML = `<thead><tr><th>Училище</th><th>Статус</th><th>Домейни</th><th>Админи</th><th>Учители</th><th>Класове</th><th>Консултации</th><th></th></tr></thead><tbody>` +
        (rows.length ? rows.map(sc => `
        <tr${activeSchool && activeSchool.id === sc.id ? ' class="row-active"' : ""}>
            <td><strong>${escapeHtml(sc.name)}</strong></td>
            <td>${escapeHtml(schoolStatusLabel(sc.status))}</td>
            <td>${escapeHtml((sc.domains || []).join(", ") || "—")}</td>
            <td class="num">${Number(sc.admins_count)}</td>
            <td class="num">${Number(sc.teachers_count)}</td>
            <td class="num">${Number(sc.classes_count)}</td>
            <td class="num">${Number(sc.consultations_count)}</td>
            <td class="cell-actions-col">
                <button class="btn-secondary btn-compact" onclick="openSchoolDetail('${escapeHtml(sc.id)}')">Детайли</button>
                <button class="btn-primary btn-compact" onclick="manageSchool('${escapeHtml(sc.id)}')">Управлявай</button>
            </td>
        </tr>`).join("") : `<tr><td colspan="8" style="padding:16px;">Няма училища според филтъра.</td></tr>`) + `</tbody>`;
}

async function createSchoolAction(btn) {
    const nameV = validateSchoolName(document.getElementById("newSchoolName").value);
    if (!nameV.ok) { schoolMsg(nameV.error, "error"); return; }
    const raw = document.getElementById("newSchoolDomain").value.trim();
    let domain = null;
    if (raw) {
        const d = validateDomainInput(raw);
        if (!d.ok) { schoolMsg(d.error, "error"); return; }
        domain = d.domain;
    }
    setBusy(btn, true, "Създаване...");
    try {
        await storage.createSchool(nameV.name, domain);
        document.getElementById("newSchoolName").value = "";
        document.getElementById("newSchoolDomain").value = "";
        await storage.loadSchools();
        renderSchoolsList();
        schoolMsg(`Училище „${nameV.name}“ е създадено.`, "success");
    } catch (error) {
        console.error(error);
        schoolMsg(friendlyError(error, "Неуспешно създаване на училище."), "error");
    } finally { setBusy(btn, false); }
}

async function openSchoolDetail(id) {
    const sc = (storage.getSchools() || []).find(x => x.id === id);
    if (!sc) return;
    document.getElementById("schoolDetailId").value = sc.id;
    document.getElementById("schoolDetailTitle").textContent = sc.name;
    document.getElementById("schoolDetailName").value = sc.name;
    document.getElementById("schoolDetailStatus").value = sc.status;
    document.getElementById("schoolDetailCounts").textContent =
        `Учители: ${sc.teachers_count} · Администратори: ${sc.admins_count} · Класове: ${sc.classes_count} · Консултации: ${sc.consultations_count}`;
    document.getElementById("schoolDetail").classList.remove("hidden");
    await Promise.all([renderDomains("sch", sc.id), renderSchoolAdmins(sc.id)]);
    document.getElementById("schoolDetail").scrollIntoView?.({ block: "nearest" });
}

function closeSchoolDetail() {
    const d = document.getElementById("schoolDetail");
    if (d) d.classList.add("hidden");
}

const detailSchoolId = () => document.getElementById("schoolDetailId").value;

async function saveSchoolAction(btn) {
    const id = detailSchoolId();
    const nameV = validateSchoolName(document.getElementById("schoolDetailName").value);
    if (!nameV.ok) { schoolMsg(nameV.error, "error"); return; }
    const status = document.getElementById("schoolDetailStatus").value;
    const cur = (storage.getSchools() || []).find(x => x.id === id);
    if (cur && cur.status === "active" && status === "inactive" &&
        !confirm(`Да бъде ли деактивирано училище „${cur.name}“?\n\nПотребителите му няма да могат да работят, докато не бъде активирано отново. Данните се запазват.`)) return;
    setBusy(btn, true, "Записване...");
    try {
        await storage.updateSchool(id, nameV.name, status);
        await storage.loadSchools();
        renderSchoolsList();
        if (activeSchool && activeSchool.id === id) activeSchool = { ...activeSchool, name: nameV.name, status };
        renderHeader();
        schoolMsg("Училището е обновено.", "success");
        await openSchoolDetail(id);
    } catch (error) {
        console.error(error);
        schoolMsg(friendlyError(error, "Неуспешно запазване."), "error");
    } finally { setBusy(btn, false); }
}

// Избор на училище за администриране: сървърът записва избора; кешът се нулира преди зареждане.
async function manageSchool(id) {
    id = id || detailSchoolId();
    if (!isSuperAdmin || !id) return;
    try {
        stopRealtime();
        const sc = await storage.setActiveSchool(id);          // нулира кеша
        activeSchool = sc;
        isAdmin = true;                                        // супер админ е админ на избраното училище
        setSchedule(null);
        await loadSchoolData();
        startRealtime();
        showTeacherScreen();
    } catch (error) {
        console.error(error);
        schoolMsg(friendlyError(error, "Неуспешен избор на училище."), "error");
        startRealtime();
    }
}

async function backToGlobalView() {
    if (!isSuperAdmin) return;
    try {
        stopRealtime();
        await storage.setActiveSchool(null);
        activeSchool = null;
        isAdmin = false;
        setSchedule(null);
        applyScheduleToUI();
        startRealtime();
        await showSchoolsScreen();
    } catch (error) {
        console.error(error);
        notify(friendlyError(error, "Неуспешно връщане към глобалния изглед."), "error");
    }
}

// ---------- администратори на училище ----------
async function renderSchoolAdmins(schoolId) {
    const t = document.getElementById("schAdminsTable");
    try {
        const list = await storage.listSchoolAdmins(schoolId);
        t.innerHTML = `<thead><tr><th>Име</th><th>Имейл</th><th>Статус</th><th></th></tr></thead><tbody>` +
            (list.length ? list.map(a => `<tr><td>${escapeHtml(a.name || "—")}</td><td>${escapeHtml(a.email || "—")}</td>
                <td>${escapeHtml(userStatusLabel(a.status))}</td>
                <td><button class="btn-danger btn-compact" onclick="removeSchoolAdminAction('${escapeHtml(a.email || "")}')">Премахни</button></td></tr>`).join("")
                : `<tr><td colspan="4">Няма администратори.</td></tr>`) + `</tbody>`;
    } catch (error) {
        t.innerHTML = `<tbody><tr><td>${escapeHtml(friendlyError(error, "Неуспешно зареждане."))}</td></tr></tbody>`;
    }
}

async function addSchoolAdminAction() {
    const v = validateInviteEmail(document.getElementById("schAdminEmail").value);
    if (!v.ok) { schoolMsg(v.error, "error"); return; }
    try {
        await storage.setSchoolAdmin(detailSchoolId(), v.email, true);
        document.getElementById("schAdminEmail").value = "";
        await storage.loadSchools(); renderSchoolsList();
        await renderSchoolAdmins(detailSchoolId());
        schoolMsg("Администраторът е назначен.", "success");
    } catch (error) { schoolMsg(friendlyError(error, "Неуспешно назначаване."), "error"); }
}

async function removeSchoolAdminAction(email) {
    if (!confirm(`Да бъде ли премахнат администраторът ${email}? (Остава като учител.)`)) return;
    try {
        await storage.setSchoolAdmin(detailSchoolId(), email, false);
        await storage.loadSchools(); renderSchoolsList();
        await renderSchoolAdmins(detailSchoolId());
        schoolMsg("Администраторът е премахнат.", "success");
    } catch (error) { schoolMsg(friendlyError(error, "Неуспешно премахване."), "error"); }
}

// ---------- домейни (prefix: "adm" = собственото училище; "sch" = избраното в екрана „Училища“) ----------
const domainMsg = (prefix, m, t) => prefix === "sch" ? schoolMsg(m, t) : showAdminStatus(m, t);
const domainSchool = prefix => prefix === "sch" ? detailSchoolId() : null;

async function renderDomains(prefix, schoolId) {
    const table = document.getElementById(prefix + "DomainsTable");
    if (!table) return;
    try {
        const list = await storage.loadDomains(schoolId);
        table.innerHTML = `<thead><tr><th>Домейн</th><th>Поддомейни</th><th>Активен</th><th>Предупреждение</th><th></th></tr></thead><tbody>` +
            (list.length ? list.map(d => `<tr>
                <td><strong>@${escapeHtml(d.domain)}</strong></td>
                <td><input type="checkbox" ${d.allow_subdomains ? "checked" : ""} aria-label="Поддомейни" onchange="toggleDomain('${prefix}', ${Number(d.id)}, 'sub', this)"></td>
                <td><input type="checkbox" ${d.active ? "checked" : ""} aria-label="Активен" onchange="toggleDomain('${prefix}', ${Number(d.id)}, 'active', this)"></td>
                <td>${Number(d.conflict_count) > 0
                    ? `<span class="warn-text">⚠ Домейнът е активен и в друго активно училище${d.conflict_names && d.conflict_names.length ? ` (${escapeHtml(d.conflict_names.join(", "))})` : ""}. Регистрацията с него се отказва – ползвайте покани.</span>` : ""}</td>
                <td><button class="btn-danger btn-compact" onclick="removeDomainAction('${prefix}', ${Number(d.id)})">Премахни</button></td>
            </tr>`).join("") : `<tr><td colspan="5">Няма домейни – регистрация по домейн не е възможна (само с покана).</td></tr>`) + `</tbody>`;
    } catch (error) {
        table.innerHTML = `<tbody><tr><td>${escapeHtml(friendlyError(error, "Неуспешно зареждане на домейните."))}</td></tr></tbody>`;
    }
}

async function addDomainAction(prefix) {
    const v = validateDomainInput(document.getElementById(prefix + "DomainInput").value);
    if (!v.ok) { domainMsg(prefix, v.error, "error"); return; }
    try {
        await storage.addDomain(v.domain, document.getElementById(prefix + "DomainSub").checked, domainSchool(prefix));
        document.getElementById(prefix + "DomainInput").value = "";
        document.getElementById(prefix + "DomainSub").checked = false;
        await renderDomains(prefix, domainSchool(prefix));
        if (prefix === "sch") { await storage.loadSchools(); renderSchoolsList(); }
        domainMsg(prefix, `Домейн @${v.domain} е добавен.`, "success");
    } catch (error) { domainMsg(prefix, friendlyError(error, "Неуспешно добавяне на домейн."), "error"); }
}

async function toggleDomain(prefix, id, which, box) {
    const d = (storage.getDomains() || []).find(x => Number(x.id) === Number(id));
    if (!d) return;
    const active = which === "active" ? box.checked : d.active;
    const sub = which === "sub" ? box.checked : d.allow_subdomains;
    if (which === "active" && !active && !confirm(`Да бъде ли деактивиран домейн @${d.domain}? Нови регистрации с него няма да се приемат.`)) { box.checked = true; return; }
    try {
        await storage.updateDomain(id, active, sub);
        domainMsg(prefix, "Домейнът е обновен.", "success");
    } catch (error) { domainMsg(prefix, friendlyError(error, "Неуспешна промяна."), "error"); }
    await renderDomains(prefix, domainSchool(prefix));
}

async function removeDomainAction(prefix, id) {
    const d = (storage.getDomains() || []).find(x => Number(x.id) === Number(id));
    if (!d || !confirm(`Да бъде ли премахнат домейн @${d.domain}? Съществуващите потребители не се засягат.`)) return;
    try {
        await storage.removeDomain(id);
        await renderDomains(prefix, domainSchool(prefix));
        if (prefix === "sch") { await storage.loadSchools(); renderSchoolsList(); }
        domainMsg(prefix, "Домейнът е премахнат.", "success");
    } catch (error) { domainMsg(prefix, friendlyError(error, "Неуспешно премахване."), "error"); }
}

// ---------- покана ----------
async function inviteTeacherAction(btn) {
    const v = validateInviteEmail(document.getElementById("inviteEmail").value);
    if (!v.ok) { showAdminStatus(v.error, "error"); return; }
    setBusy(btn, true, "Изпращане...");
    try {
        await storage.inviteTeacher(v.email, null);
        document.getElementById("inviteEmail").value = "";
        showAdminStatus(`Поканата за ${v.email} е записана. Потребителят може да се регистрира с този имейл.`, "success");
    } catch (error) { showError(error, "Неуспешна покана."); }
    finally { setBusy(btn, false); }
}

// ---------- график на часовете ----------
async function renderScheduleAdmin() {
    const box = document.getElementById("scheduleEditor");
    if (!box) return;
    await storage.loadSchedule(true);
    setSchedule(storage.getSchedule());
    applyScheduleToUI();
    const sch = getSchedule();
    document.getElementById("scheduleModeSelect").value = sch.mode;
    document.getElementById("scheduleModeInfo").textContent = sch.mode === "one_shift"
        ? "Една смяна: интервалите се задават свободно (до 14). Добавяне – само в края; премахва се само последният неизползван."
        : "Две смени: 7 позиции на смяна; I смяна → 12:35–18:30, II смяна → 07:30–13:15 (по подразбиране). Часовете може да се коригират.";
    const byShift = sh => sch.intervals.filter(i => i.shift === sh);
    const block = sh => {
        const list = byShift(sh);
        const last = list.length ? list[list.length - 1].position : 0;
        return `<h4>${escapeHtml(sch.mode === "one_shift" ? "Единна смяна" : shiftName(sh))}</h4>
        <div class="schedule-wrapper"><table class="classes-table"><thead><tr><th>№</th><th>Начало</th><th>Край</th><th>Консултации</th><th></th></tr></thead><tbody>` +
            list.map(i => `<tr>
                <td>${i.position}</td>
                <td><input type="time" id="iv_s_${sh}_${i.position}" value="${escapeHtml(i.start)}" aria-label="Начало ${i.position}"></td>
                <td><input type="time" id="iv_e_${sh}_${i.position}" value="${escapeHtml(i.end)}" aria-label="Край ${i.position}"></td>
                <td class="num">${i.used == null ? "—" : i.used}</td>
                <td class="cell-actions-col">
                    <button class="btn-primary btn-compact" onclick="saveIntervalAction(${sh}, ${i.position}, this)">Запази</button>
                    ${sch.mode === "one_shift" && i.position === last && list.length > 1 ? `<button class="btn-danger btn-compact" onclick="deleteIntervalAction(${sh}, ${i.position})">Премахни</button>` : ""}
                </td></tr>`).join("") +
            (sch.mode === "one_shift" && last < 14 ? `<tr><td>${last + 1}</td>
                <td><input type="time" id="iv_s_${sh}_${last + 1}" aria-label="Ново начало"></td>
                <td><input type="time" id="iv_e_${sh}_${last + 1}" aria-label="Нов край"></td><td></td>
                <td><button class="btn-secondary btn-compact" onclick="saveIntervalAction(${sh}, ${last + 1}, this)">Добави</button></td></tr>` : "") +
            `</tbody></table></div>`;
    };
    box.innerHTML = activeShifts().map(block).join("");
}

async function changeScheduleMode(btn) {
    const mode = document.getElementById("scheduleModeSelect").value;
    if (mode === scheduleMode()) { showAdminStatus("Режимът вече е този.", "success"); return; }
    setBusy(btn, true, "Проверка...");
    try {
        const impact = await storage.scheduleImpact(mode);
        if (impact.blocked) { showAdminStatus(impact.reason, "error"); return; }
        const total = Number(impact.consultations_total) || 0;
        const text = `Да бъде ли сменен режимът на „${scheduleModeLabel(mode)}“?\n\n` +
            (total ? `Съществуващите консултации (${total}) НЕ се изтриват и не се променят; променя се само показването на часовете.\n` : "") +
            `Консултациите са по ден + смяна + час.`;
        if (!confirm(text)) return;
        await storage.setScheduleMode(mode, true);
        setSchedule(storage.getSchedule());
        await storage.refresh();
        applyScheduleToUI();
        renderViews();
        await renderScheduleAdmin();
        showAdminStatus("Режимът е сменен.", "success");
    } catch (error) { showError(error, "Неуспешна смяна на режима."); }
    finally { setBusy(btn, false); }
}

async function saveIntervalAction(shift, position, btn) {
    const start = document.getElementById(`iv_s_${shift}_${position}`).value;
    const end = document.getElementById(`iv_e_${shift}_${position}`).value;
    const list = getSchedule().intervals.filter(i => i.shift === shift);
    const prev = list.find(i => i.position === position - 1);
    const next = list.find(i => i.position === position + 1);
    const v = validateIntervalInput({ start, end, prevEnd: prev ? prev.end : "", nextStart: next ? next.start : "" });
    if (!v.ok) { showAdminStatus(v.errors.join("\n"), "error"); return; }
    const cur = list.find(i => i.position === position);
    const used = cur && cur.used ? cur.used : 0;
    let confirmed = false;
    if (cur && used && (cur.start !== v.start || cur.end !== v.end)) {
        if (!confirm(`Интервалът се използва от ${used} консултации. Промяната на часа ще се отрази на всички. Да продължа ли?`)) return;
        confirmed = true;
    }
    setBusy(btn, true, "Записване...");
    try {
        await storage.saveInterval(shift, position, v.start, v.end, confirmed);
        setSchedule(storage.getSchedule());
        applyScheduleToUI();
        renderViews();
        await renderScheduleAdmin();
        showAdminStatus("Интервалът е запазен.", "success");
    } catch (error) { showError(error, "Неуспешно запазване на интервала."); }
    finally { setBusy(btn, false); }
}

async function deleteIntervalAction(shift, position) {
    if (!confirm(`Да бъде ли премахнат интервал ${position}?`)) return;
    try {
        await storage.deleteInterval(shift, position);
        setSchedule(storage.getSchedule());
        applyScheduleToUI();
        renderViews();
        await renderScheduleAdmin();
        showAdminStatus("Интервалът е премахнат.", "success");
    } catch (error) { showError(error, "Неуспешно премахване."); }
}
