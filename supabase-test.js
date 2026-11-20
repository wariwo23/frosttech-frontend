const SUPABASE_URL = "https://gqnidjifiobhqhnxjlow.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_epS9WBwMNlSIgxQ3JXHQIw_4JvBO-sL";

if (!window.supabase || !window.supabase.createClient) {
  throw new Error("Supabase JavaScript library did not load.");
}

if (!window.supabaseClient) {
  window.supabaseClient = window.supabase.createClient(
    SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY,
    {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    }
  );
}
