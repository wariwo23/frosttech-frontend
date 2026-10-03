const SUPABASE_URL = "https://nftxptjpgidcsgtaltjn.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "[KEY]";

const supabaseClient = supabase.createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY
);
