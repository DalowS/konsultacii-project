/*
 * STORAGE LAYER -> Supabase.
 * Запазва същия интерфейс като старата версия. getAll() остава синхронна
 * (връща кеш), а refresh() зарежда свежите данни от базата.
 * Записващите методи са async и хвърлят грешка при неуспех.
 * localStorage НЕ се използва за данни.
 */
const storage = {
    _cache: [],
    _classes: [],          // [{id,name}]
    _groupSubjects: [],    // [{id,subject,enabled}]
    _teachers: [],         // [{id,name,role}]
    _settings: null,       // {school_name, academic_year, current_term} или null (още няма миграция/настройки)
    _users: null,          // [{id,name,email,role,status,created_at}] само за админ; null = не е заредено

    getAll() { return this._cache; },
    getClassNames() { return this._classes.map(c => c.name); },
    getClasses() { return this._classes; },
    getGroupSubjectRows() { return this._groupSubjects; },
    getTeachers() { return this._teachers; },
    getSettings() { return this._settings; },
    getUsers() { return this._users; },

    async refresh() {
        const [consultations, classes, groups, teachers] = await Promise.all([
            this._fetchConsultations(),
            this._q(sb.from("classes").select("id,name")),
            this._q(sb.from("group_subjects").select("id,subject,enabled").order("subject")),
            this._q(sb.from("teachers").select("id,name,role").order("name"))
        ]);
        this._classes = classes.sort((a, b) => compareClassNames(a.name, b.name));
        this._groupSubjects = groups;
        this._teachers = teachers;
        const order = new Map(this._classes.map((c, i) => [c.name, i]));
        this._cache = consultations.map(row => {
            const names = (row.consultation_classes || [])
                .map(cc => cc.classes && cc.classes.name).filter(Boolean)
                .sort((a, b) => (order.get(a) ?? 0) - (order.get(b) ?? 0));
            return {
                id: String(row.id),
                teacherId: row.teacher_id,
                teacher: row.teachers ? row.teachers.name : "",
                day: indexToDay(row.day),
                shift: row.shift,
                hour: row.hour,
                subject: row.subject,
                location: row.location || "",
                classes: names,
                className: names[0] || ""
            };
        });
    },

    // Една заявка с join (consultation + teacher + classes); страниране заради лимита от 1000.
    async _fetchConsultations() {
        const out = [], size = 1000;
        for (let from = 0; ; from += size) {
            const rows = await this._q(sb.from("consultations")
                .select("id,teacher_id,day,shift,hour,subject,location,teachers(name),consultation_classes(classes(name))")
                .order("id").range(from, from + size - 1));
            out.push(...rows);
            if (rows.length < size) break;
        }
        return out;
    },

    async _q(query) {
        const { data, error } = await query;
        if (error) throw error;
        return data || [];
    },

    _payload(id, r) {
        return {
            p_id: id ? Number(id) : null,
            p_day: dayToIndex(r.day),
            p_shift: Number(r.shift),
            p_hour: Number(r.hour),
            p_subject: r.subject,
            p_location: r.location || null,
            p_classes: normalizeClasses(r)
        };
    },

    // Атомарно: консултация + класове + проверка за конфликти на сървъра.
    async add(record) {
        const { error } = await sb.rpc("save_consultation", this._payload(null, record));
        if (error) throw error;
        await this.refresh();
    },

    async update(id, record) {
        const { error } = await sb.rpc("save_consultation", this._payload(id, record));
        if (error) throw error;
        await this.refresh();
    },

    async delete(id) {
        // RLS мълчаливо изтрива 0 реда при липса на право -> проверяваме резултата.
        const { data, error } = await sb.from("consultations").delete().eq("id", Number(id)).select("id");
        if (error) throw error;
        if (!data || !data.length) {
            const e = new Error("Записът не е изтрит (няма право или вече не съществува).");
            e.code = "CS001";
            throw e;
        }
        await this.refresh();
    },

    async clear() {
        const { data, error } = await sb.rpc("admin_clear_consultations");
        if (error) throw error;
        await this.refresh();
        return data;
    },

    async importItems(items, replace) {
        const { data, error } = await sb.rpc("import_consultations", { p_items: items, p_replace: !!replace });
        if (error) throw error;
        await this.refresh();
        return data;
    },

    async setGroupSubject(subject, enabled) {
        const { error } = await sb.from("group_subjects")
            .upsert({ subject, enabled }, { onConflict: "subject" });
        if (error) throw error;
    },

    async updateTeacher(id, patch) {
        const { error } = await sb.from("teachers").update(patch).eq("id", id);
        if (error) throw error;
    },

    // Класове – валидация и нормализация и на сървъра (RPC); изтриването е защитено от trigger.
    async addClass(grade, letter) {
        const { error } = await sb.rpc("admin_add_class", { p_grade: Number(grade), p_letter: letter });
        if (error) throw error;
        await this.refresh();
    },

    async deleteClass(id) {
        const { data, error } = await sb.from("classes").delete().eq("id", Number(id)).select("id");
        if (error) throw error;
        if (!data || !data.length) {
            const e = new Error("Класът не е изтрит (няма право или вече не съществува).");
            e.code = "CS001";
            throw e;
        }
        await this.refresh();
    },

    // Изтрива Auth акаунта + консултациите в една транзакция (SECURITY DEFINER RPC, без service_role).
    async deleteTeacher(id) {
        const { data, error } = await sb.rpc("admin_delete_teacher", { p_teacher: id });
        if (error) throw error;
        await this.refresh();
        return data;
    },

    // v2.9: настройки на училището (един ред). Четат се от всички влезли; пишат се само през RPC (админ).
    // Грешка при четене не бива да блокира графика (напр. миграцията още не е приложена) -> null.
    async loadSettings() {
        try {
            const { data, error } = await sb.from("school_settings")
                .select("school_name,academic_year,current_term").eq("id", 1).maybeSingle();
            if (error) throw error;
            this._settings = data || null;
        } catch (error) {
            console.error(error);
            this._settings = null;
        }
        return this._settings;
    },

    async saveSettings(values) {
        const { data, error } = await sb.rpc("admin_update_school_settings", {
            p_school_name: values.school_name,
            p_academic_year: values.academic_year,
            p_current_term: values.current_term
        });
        if (error) throw error;
        this._settings = {
            school_name: data.school_name, academic_year: data.academic_year, current_term: data.current_term
        };
        return this._settings;
    },

    // v2.9: потребители с имейл/статус/дата – само админ (SECURITY DEFINER RPC, без service_role).
    async loadUsers() {
        try {
            const { data, error } = await sb.rpc("admin_list_users");
            if (error) throw error;
            this._users = data || [];
        } catch (error) {
            console.error(error);
            this._users = null;
        }
        return this._users;
    }
};
