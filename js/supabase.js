/* Инициализация на Supabase клиента (supabase-js се зарежда от CDN в index.html). */
let sb = null;
let configError = "";

(function initSupabase() {
    const cfg = window.APP_CONFIG || {};
    if (!window.supabase || !window.supabase.createClient) {
        configError = "Не може да се зареди Supabase библиотеката. Проверете интернет връзката.";
    } else if (!cfg.SUPABASE_URL || !cfg.SUPABASE_PUBLISHABLE_KEY ||
               cfg.SUPABASE_PUBLISHABLE_KEY.startsWith("PASTE_")) {
        configError = "Липсва Supabase publishable key в js/config.js.";
    } else {
        sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_PUBLISHABLE_KEY, {
            auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
        });
    }
})();
