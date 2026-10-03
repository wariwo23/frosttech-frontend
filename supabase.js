const SUPABASE_URL = "https://nftxptjpgidcsgtaltjn.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5mdHhwdGpwZ2lkY3NndGFsdGpuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3NjI2NTUsImV4cCI6MjEwNjMzODY1NX0.TJc8bkEqdyc_yuv8oTiKQApd3L5j2ppASi-9zr-WtP0";

const supabaseClient = supabase.createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY
);
