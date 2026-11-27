-- FrostTech production security hardening
-- Remove TRUNCATE from public API client roles on existing public tables.
-- Deliberately preserves SELECT/INSERT/UPDATE/DELETE grants, RLS policies,
-- service_role privileges, table data, functions, and triggers.
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
