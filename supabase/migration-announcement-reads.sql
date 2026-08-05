-- ============================================================================
--  Migration: per-parent announcement read state
--  ----------------------------------------------------------------------------
--  Backs the inline announcements feed in the family portal: each parent needs
--  their own read/unread state per announcement, so one parent marking an
--  announcement read must not affect any other parent.
--
--  Parents are Supabase Auth users, so rows are keyed on auth.uid(). (Note the
--  rest of the parent side keys on auth.email() via card_links.parent_email;
--  uid is used here because it is stable if a parent ever changes their email,
--  and it makes the RLS policy a direct comparison with no joins.)
--
--  ADDITIVE: one new table. No existing table, column, policy or function is
--  altered, and no data is read, modified or deleted.
--
--  Run ONCE in the Supabase SQL editor.
-- ============================================================================

create table if not exists public.announcement_reads (
  id              uuid primary key default gen_random_uuid(),
  parent_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  read_at         timestamptz not null default now(),
  unique (parent_id, announcement_id)
);
create index if not exists announcement_reads_parent_idx on public.announcement_reads(parent_id);

alter table public.announcement_reads enable row level security;

-- Base table privileges. This schema grants table access with a one-time
-- "grant ... on all tables" snapshot (schema.sql), NOT alter default
-- privileges, so a table added later must grant explicitly — otherwise every
-- write fails with "permission denied for table announcement_reads" before RLS
-- is even evaluated. (Same trap that bit the teachers/groups migration.)
grant select, insert, update, delete on public.announcement_reads to authenticated;

-- A parent may only ever see or write their own read markers.
drop policy if exists announcement_reads_select_own on public.announcement_reads;
create policy announcement_reads_select_own on public.announcement_reads
  for select using (parent_id = auth.uid());

drop policy if exists announcement_reads_insert_own on public.announcement_reads;
create policy announcement_reads_insert_own on public.announcement_reads
  for insert with check (parent_id = auth.uid());

drop policy if exists announcement_reads_update_own on public.announcement_reads;
create policy announcement_reads_update_own on public.announcement_reads
  for update using (parent_id = auth.uid()) with check (parent_id = auth.uid());

drop policy if exists announcement_reads_delete_own on public.announcement_reads;
create policy announcement_reads_delete_own on public.announcement_reads
  for delete using (parent_id = auth.uid());

-- ============================================================================
--  Done. Sanity checks:
--    select * from public.announcement_reads;                  -- 0 rows, no error
--    select table_name, privilege_type
--      from information_schema.role_table_grants
--     where table_name='announcement_reads' and grantee='authenticated';
--    -- expect SELECT / INSERT / UPDATE / DELETE
--
--  ROLLBACK (removes only this table and its read markers):
--    drop table if exists public.announcement_reads;
-- ============================================================================
