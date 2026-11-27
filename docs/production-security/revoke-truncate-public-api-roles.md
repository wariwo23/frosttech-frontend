# Production security correction: public-table TRUNCATE

Status: applied to production and verified.

Migration: `20261127104630_revoke_anon_authenticated_truncate_public_tables.sql`

Project: FrostTech production Supabase project `nftxptjpgidcsgtaltjn`.

## Scope

Removed the PostgreSQL `TRUNCATE` privilege from `anon` and `authenticated` on all existing tables in the `public` schema.

Preserved:
- Existing SELECT, INSERT, UPDATE and DELETE grants.
- Existing RLS policies.
- Service-role permissions.
- Existing data, triggers, functions and table definitions.

## Verification

After migration, a catalog privilege check across all public tables returned zero tables on which either `anon` or `authenticated` has `TRUNCATE`.

## Outstanding follow-up

The audit also found broad default privileges for future public tables under the `postgres` and `supabase_admin` owners. The migration runner could not alter those default ACLs (PostgreSQL returned permission denied to change default privileges), so no default-privilege change was applied. Existing-table protection is complete; future-table default ACL hardening remains an explicit follow-up requiring an authorized owner-level migration path.

Rollback SQL is supplied separately. It restores broad TRUNCATE privileges and must not be run except with explicit approval and a documented reason.
