-- ROLLBACK COMPANION ONLY — DO NOT RUN DURING NORMAL OPERATIONS.
-- Restores broad TRUNCATE privileges to anon and authenticated on all
-- existing public tables, matching the pre-migration exposure pattern.
-- This is intentionally destructive-risk restoration and requires explicit
-- Super Administrator approval and a documented incident reason.
GRANT TRUNCATE ON ALL TABLES IN SCHEMA public TO anon, authenticated;
