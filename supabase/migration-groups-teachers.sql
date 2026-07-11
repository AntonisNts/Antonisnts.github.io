-- ============================================================================
--  Migration: real GROUPS + TEACHERS (staging first)
--  ----------------------------------------------------------------------------
--  Turns "group" from a free-text string typed onto each student card into a
--  proper record, and introduces a teacher entity that lives on the GROUP
--  (not on the student, and not typed into the group's name).
--
--    teachers   : id, business_id, name
--    groups     : id, business_id, name, schedule (jsonb), teacher_id
--    cards      : + group_id  ->  groups(id)
--
--  ADDITIVE + BACKWARD-COMPATIBLE: the existing cards.group_name and
--  cards.lesson_schedule columns are LEFT IN PLACE and untouched, so the
--  current frontend keeps working unchanged until it is cut over to group_id
--  in a later step. This migration only adds tables/columns and teaches the
--  two student-facing RPCs to also return the joined group (with teacher).
--
--  NO DATA LOSS: only CREATE TABLE / CREATE INDEX / ADD COLUMN / CREATE POLICY /
--  CREATE OR REPLACE FUNCTION. No DROP TABLE, DROP COLUMN, DELETE, UPDATE or
--  TRUNCATE anywhere — no existing row is read-modified or removed. The two
--  functions are REPLACED (reversible: re-run migration-flip-card.sql to
--  restore the previous versions).
--
--  Run ONCE in the Supabase SQL editor. (This project's single DB serves both
--  the staging and production sites — see rollback block at the end of file.)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. teachers  (a teacher belongs to one business; reused across many groups)
-- ---------------------------------------------------------------------------
create table if not exists public.teachers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists teachers_business_id_idx on public.teachers(business_id);

alter table public.teachers enable row level security;

-- Base table privileges. This schema grants access with a one-time
-- "grant ... on all tables" snapshot (schema.sql), NOT alter default
-- privileges, so tables added later must grant explicitly — otherwise writes
-- fail with "permission denied for table teachers" before RLS is evaluated.
-- (RLS policies below still enforce per-business isolation on top.)
grant select, insert, update, delete on public.teachers to authenticated;

-- Owner of the (approved) business may see/manage only their own teachers.
drop policy if exists teachers_select_own on public.teachers;
create policy teachers_select_own on public.teachers
  for select using (exists (
    select 1 from public.businesses b
    where b.id = teachers.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists teachers_insert_own on public.teachers;
create policy teachers_insert_own on public.teachers
  for insert with check (exists (
    select 1 from public.businesses b
    where b.id = business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists teachers_update_own on public.teachers;
create policy teachers_update_own on public.teachers
  for update using (exists (
    select 1 from public.businesses b
    where b.id = teachers.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists teachers_delete_own on public.teachers;
create policy teachers_delete_own on public.teachers
  for delete using (exists (
    select 1 from public.businesses b
    where b.id = teachers.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

-- ---------------------------------------------------------------------------
-- 2. groups  (owns its own name, schedule and assigned teacher)
-- ---------------------------------------------------------------------------
--  schedule uses the same shape already stored in cards.lesson_schedule:
--    [{ "day": "Monday", "start_time": "17:00", "end_time": "18:00" }, ...]
--  teacher_id is nullable and set null if the teacher record is removed.
--  unique(business_id, name) prevents duplicate group names within a business.
create table if not exists public.groups (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  schedule     jsonb not null default '[]'::jsonb,
  teacher_id   uuid references public.teachers(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (business_id, name)
);
create index if not exists groups_business_id_idx on public.groups(business_id);
create index if not exists groups_teacher_id_idx  on public.groups(teacher_id);

alter table public.groups enable row level security;

grant select, insert, update, delete on public.groups to authenticated;

drop policy if exists groups_select_own on public.groups;
create policy groups_select_own on public.groups
  for select using (exists (
    select 1 from public.businesses b
    where b.id = groups.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists groups_insert_own on public.groups;
create policy groups_insert_own on public.groups
  for insert with check (exists (
    select 1 from public.businesses b
    where b.id = business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists groups_update_own on public.groups;
create policy groups_update_own on public.groups
  for update using (exists (
    select 1 from public.businesses b
    where b.id = groups.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists groups_delete_own on public.groups;
create policy groups_delete_own on public.groups
  for delete using (exists (
    select 1 from public.businesses b
    where b.id = groups.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

-- ---------------------------------------------------------------------------
-- 3. cards.group_id  (student references a group by id; keep old columns)
-- ---------------------------------------------------------------------------
--  on delete set null: deleting a group leaves its students in place, just
--  un-assigned (it does NOT delete students).
alter table public.cards
  add column if not exists group_id uuid references public.groups(id) on delete set null;
create index if not exists cards_group_id_idx on public.cards(group_id);

-- ---------------------------------------------------------------------------
-- 4. get_my_cards(): also return the joined group (+ teacher name)
-- ---------------------------------------------------------------------------
--  Keeps group_name + lesson_schedule for backward compatibility, and adds a
--  new 'group' object plus 'group_id' on each card. group is null when the
--  card isn't assigned to a group yet.
create or replace function public.get_my_cards()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r record;
begin
  if v_email is null then return result; end if;
  for r in
    select c.id, c.name, c.level, c.share_code, c.payments, c.history,
           c.enrollment_start_month, c.paused_months, c.fee_history,
           c.group_name, c.lesson_schedule, c.group_id, cl.child_id,
           g.name as g_name, g.schedule as g_schedule, g.teacher_id as g_teacher_id,
           t.name as g_teacher_name,
           b.name as b_name, b.type as b_type, b.fee as b_fee, b.year as b_year,
           b.biz_code as b_code, b.inactive_months as b_inactive,
           b.levels as b_levels, b.custom_card_image as b_image
    from public.card_links cl
    join public.cards c        on c.id = cl.card_id
    join public.businesses b   on b.id = c.business_id
    left join public.groups g  on g.id = c.group_id
    left join public.teachers t on t.id = g.teacher_id
    where cl.parent_email = v_email
    order by c.name
  loop
    result := result || jsonb_build_object(
      'card', jsonb_build_object(
        'id', r.id, 'name', r.name, 'level', r.level, 'share_code', r.share_code,
        'payments', r.payments, 'history', r.history,
        'enrollment_start_month', r.enrollment_start_month,
        'paused_months', r.paused_months, 'fee_history', r.fee_history,
        'group_name', r.group_name, 'lesson_schedule', r.lesson_schedule,
        'group_id', r.group_id,
        'group', case when r.group_id is null then null else jsonb_build_object(
          'id', r.group_id, 'name', r.g_name, 'schedule', r.g_schedule,
          'teacher_id', r.g_teacher_id, 'teacher_name', r.g_teacher_name) end,
        'child_id', r.child_id),
      'business', jsonb_build_object(
        'name', r.b_name, 'type', r.b_type, 'fee', r.b_fee, 'year', r.b_year,
        'biz_code', r.b_code, 'inactive_months', r.b_inactive,
        'levels', r.b_levels, 'custom_card_image', r.b_image)
    );
  end loop;
  return result;
end;
$$;
grant execute on function public.get_my_cards() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. get_student_card(): also return the joined group (+ teacher name)
-- ---------------------------------------------------------------------------
--  Unchanged rate-limiting / PIN logic; adds a 'group' object and 'group_id'
--  to the returned card. Keeps group_name + lesson_schedule as-is.
create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v_fails int;
  c public.cards%rowtype;
  b public.businesses%rowtype;
  v_ann jsonb;
  v_group jsonb := null;
begin
  delete from public.pin_attempts where attempted_at < now() - interval '1 day';
  select count(*) into v_fails from public.pin_attempts
   where share_code = v_code and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then return jsonb_build_object('locked', true); end if;

  select * into c from public.cards where share_code = v_code limit 1;
  if not found or c.pin is null or c.pin <> p_pin then
    insert into public.pin_attempts(share_code) values (v_code);
    return null;
  end if;

  delete from public.pin_attempts where share_code = v_code;
  select * into b from public.businesses where id = c.business_id;

  if c.group_id is not null then
    select jsonb_build_object(
             'id', g.id, 'name', g.name, 'schedule', g.schedule,
             'teacher_id', g.teacher_id, 'teacher_name', t.name)
      into v_group
      from public.groups g
      left join public.teachers t on t.id = g.teacher_id
      where g.id = c.group_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'title', a.title, 'body', a.body,
           'image_url', a.image_url, 'is_pinned', a.is_pinned,
           'created_at', a.created_at) order by a.is_pinned desc, a.created_at desc), '[]'::jsonb)
    into v_ann
    from public.announcements a
    where a.business_id = b.id
      and a.is_active
      and (a.expires_at is null or a.expires_at > now());

  return jsonb_build_object(
    'business', jsonb_build_object(
      'name', b.name, 'type', b.type, 'fee', b.fee, 'year', b.year,
      'biz_code', b.biz_code, 'inactive_months', b.inactive_months,
      'levels', b.levels, 'custom_card_image', b.custom_card_image),
    'card', jsonb_build_object(
      'name', c.name, 'level', c.level, 'share_code', c.share_code,
      'payments', c.payments, 'history', c.history,
      'enrollment_start_month', c.enrollment_start_month,
      'paused_months', c.paused_months, 'fee_history', c.fee_history,
      'group_name', c.group_name, 'lesson_schedule', c.lesson_schedule,
      'group_id', c.group_id, 'group', v_group),
    'announcements', v_ann
  );
end;
$$;
grant execute on function public.get_student_card(text, text) to anon, authenticated;

-- ============================================================================
--  Done. Sanity checks:
--    select id, name from public.teachers;
--    select g.id, g.name, g.schedule, t.name as teacher
--      from public.groups g left join public.teachers t on t.id = g.teacher_id;
--    select id, name, group_id, group_name from public.cards;
--
--  Next (separate steps, not in this migration):
--    - create teachers, then groups (name + schedule + teacher_id)
--    - assign / bulk-load students with group_id
--    - cut the frontend over from group_name string to group_id
--    - only AFTER cutover: consider dropping cards.group_name / lesson_schedule
-- ============================================================================

-- ============================================================================
--  ROLLBACK (only if you need to fully undo this migration). Safe as long as
--  you have not started assigning cards.group_id. Run in the SQL editor:
--
--    alter table public.cards drop column if exists group_id;
--    drop table if exists public.groups;      -- groups you created are removed
--    drop table if exists public.teachers;    -- teachers you created are removed
--    -- then re-run migration-flip-card.sql to restore the previous
--    -- get_my_cards() / get_student_card() definitions.
--
--  This touches ONLY the new objects + the two functions; businesses, cards
--  (rows), card_links, children, announcements and payments are never affected.
-- ============================================================================
