/* AUTH – Supabase Auth. Ролята идва от public.teachers (не от клиента). */
let currentUser = null;      // { id, name, role, email }
let isAdmin = false;
let currentTeacher = "";     // показвано име (съвместимост със стария код)

const auth = {
    async signIn(email, password) {
        const { error } = await sb.auth.signInWithPassword({ email, password });
        if (error) throw error;
    },
    async signUp(name, email, password) {
        const { data, error } = await sb.auth.signUp({ email, password, options: { data: { name } } });
        if (error) throw error;
        return data;           // data.session е null, ако е нужно потвърждение по имейл
    },
    async signOut() { await sb.auth.signOut(); },
    async getSession() { return (await sb.auth.getSession()).data.session; },
    // v2.9: смяна на парола. Първо повторна проверка на текущата парола със същия имейл,
    // после updateUser. Паролите не се записват и не се логват никъде.
    async changePassword(email, currentPassword, newPassword) {
        const { error: reauthError } = await sb.auth.signInWithPassword({ email, password: currentPassword });
        if (reauthError) {
            const e = new Error("Текущата парола е грешна.");
            e.code = "WRONG_CURRENT_PASSWORD";
            throw e;
        }
        const { error } = await sb.auth.updateUser({ password: newPassword });
        if (error) throw error;
    },
    async loadProfile(user) {
        const { data, error } = await sb.from("teachers")
            .select("id,name,role").eq("id", user.id).maybeSingle();
        if (error) throw error;
        if (!data) throw new Error("Липсва профил на учител за този потребител.");
        return { ...data, email: user.email };
    }
};
