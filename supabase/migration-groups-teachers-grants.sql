-- ============================================================================
--  Fix: grant table privileges on teachers + groups to `authenticated`
--  ----------------------------------------------------------------------------
--  migration-groups-teachers.sql created the teachers/groups tables with RLS
--  policies but did NOT grant base table privileges. This schema grants table
--  access with a ONE-TIME snapshot ("grant ... on all tables in schema public
--  to authenticated", schema.sql), not ALTER DEFAULT PRIVILEGES — so tables
--  added afterwards get no privileges automatically and every write fails with
--  "permission denied for table ..." BEFORE RLS is even evaluated.
--
--  This grant does NOT bypass RLS: the per-business owner policies on both
--  tables still apply on top (same as cards/businesses/announcements).
--
--  Idempotent — safe to run once, in the Supabase SQL editor.
-- ============================================================================

grant select, insert, update, delete on public.teachers to authenticated;
grant select, insert, update, delete on public.groups   to authenticated;

-- Sanity check (should now list SELECT/INSERT/UPDATE/DELETE for each table):
--   select table_name, grantee, privilege_type
--   from information_schema.role_table_grants
--   where table_schema='public' and table_name in ('teachers','groups')
--     and grantee='authenticated'
--   order by table_name, privilege_type;
