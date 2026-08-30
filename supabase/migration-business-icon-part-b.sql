-- ============================================================================
--  Migration: an owner-chosen school icon  (PART B — the two read paths)
--  ----------------------------------------------------------------------------
--  Part A added businesses.icon. It works for the OWNER, because the dashboard
--  reads the row directly with select *. Parents and students do not: they read
--  their school through get_my_cards() and get_student_card(), which build the
--  business object key by key. Until those return `icon`, an owner sees their
--  chosen icon and everybody else still sees the category's.
--
--  ----------------------------------------------------------------------------
--  WHERE THESE BODIES CAME FROM
--
--  Both were dumped from the LIVE database with pg_get_functiondef on
--  30/08/2026, not reconstructed from this repo. That matters: the repo's SQL
--  has been behind the live database twice, and get_student_card was last
--  recreated by migration-announcement-targeting.sql rather than by the accent
--  migration. Rebuilding it from the wrong file would silently drop the
--  targeting filter, and a note written for ONE student would become readable
--  by every student at that school.
--
--  Everything below is the live body verbatim, reformatted for reading, with
--  exactly three added lines, each marked <-- ICON:
--
--    get_my_cards      b.icon as b_icon        in the select list
--                      'icon', r.b_icon        in the business object
--    get_student_card  'icon', b.icon          in the business object
--                                              (b is businesses%rowtype, so no
--                                               select-list change is needed)
--
--  The blocks marked <-- TARGETING are the announcement targeting rules,
--  carried across unchanged. If they are not present after running this, stop.
--
--  ----------------------------------------------------------------------------
--  Run ONCE in the Supabase SQL editor, AFTER migration-business-icon.sql.
--  Safe to re-run: both are CREATE OR REPLACE and neither reads or writes data.
-- ============================================================================


-- ---------------------------------------------------------------------------
--  1. The parent's card list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_cards()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r       record;
begin
  if v_email is null then return result; end if;

  for r in
    select c.id, c.name, c.level, c.share_code, c.payments, c.history,
           c.enrollment_start_month, c.paused_months, c.fee_history,
           c.group_name, c.lesson_schedule, c.group_id,
           cl.child_id,
           g.name as g_name, g.schedule as g_schedule,
           g.teacher_id as g_teacher_id, t.name as g_teacher_name,
           b.name as b_name, b.type as b_type, b.fee as b_fee, b.year as b_year,
           b.biz_code as b_code, b.inactive_months as b_inactive,
           b.levels as b_levels, b.custom_card_image as b_image,
           b.accent as b_accent,
           b.icon as b_icon                                    -- <-- ICON
      from public.card_links cl
      join public.cards c      on c.id = cl.card_id
      join public.businesses b on b.id = c.business_id
      left join public.groups g   on g.id = c.group_id
      left join public.teachers t on t.id = g.teacher_id
     where cl.parent_email = v_email
     order by c.name
  loop
    result := result || jsonb_build_object(
      'card', jsonb_build_object(
        'id', r.id, 'name', r.name, 'level', r.level,
        'share_code', r.share_code, 'payments', r.payments, 'history', r.history,
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
        'levels', r.b_levels, 'custom_card_image', r.b_image,
        'accent', r.b_accent,
        'icon', r.b_icon)                                      -- <-- ICON
    );
  end loop;

  return result;
end;
$function$;


-- ---------------------------------------------------------------------------
--  2. The student's own view
--
--      This is the one that carries the announcement targeting filter. It is
--      reproduced exactly as it runs today; only the business object gains a
--      key.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_student_card(p_code text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code  text := upper(trim(p_code));
  v_fails int;
  c       public.cards%rowtype;
  b       public.businesses%rowtype;
  v_ann   jsonb;
  v_group jsonb := null;
begin
  delete from public.pin_attempts where attempted_at < now() - interval '1 day';

  select count(*) into v_fails
    from public.pin_attempts
   where share_code = v_code
     and attempted_at > now() - interval '15 minutes';
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

  select coalesce(
           jsonb_agg(jsonb_build_object(
             'id', a.id, 'title', a.title, 'body', a.body,
             'image_url', a.image_url, 'is_pinned', a.is_pinned,
             'created_at', a.created_at,
             'target_kind', case when a.card_id is not null then 'student'
                                 when a.group_id is not null then 'group'
                                 else 'all' end,                -- <-- TARGETING
             'target_name', coalesce(tc.name, g2.name))         -- <-- TARGETING
             order by a.is_pinned desc, a.created_at desc),
           '[]'::jsonb)
    into v_ann
    from public.announcements a
    left join public.groups g2 on g2.id = a.group_id            -- <-- TARGETING
    left join public.cards tc  on tc.id = a.card_id             -- <-- TARGETING
   where a.business_id = b.id
     and a.is_active
     and (a.expires_at is null or a.expires_at > now())
     -- <-- TARGETING: the whole school, this student's class, or this student.
     and ((a.group_id is null and a.card_id is null)
          or a.card_id = c.id
          or (a.group_id is not null and a.group_id = c.group_id));

  return jsonb_build_object(
    'business', jsonb_build_object(
      'name', b.name, 'type', b.type, 'fee', b.fee, 'year', b.year,
      'biz_code', b.biz_code, 'inactive_months', b.inactive_months,
      'levels', b.levels, 'custom_card_image', b.custom_card_image,
      'accent', b.accent,
      'icon', b.icon),                                          -- <-- ICON
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
$function$;


-- ---------------------------------------------------------------------------
--  3. Grants
--
--      CREATE OR REPLACE keeps existing privileges, so these are belt and
--      braces — and they restate the rule that matters: Postgres grants EXECUTE
--      to PUBLIC on every new function, so a grant to `authenticated` restricts
--      nothing without the revoke first.
-- ---------------------------------------------------------------------------
revoke all on function public.get_my_cards() from public, anon;
grant execute on function public.get_my_cards() to authenticated;

revoke all on function public.get_student_card(text,text) from public;
grant execute on function public.get_student_card(text,text) to anon, authenticated;


-- ============================================================================
--  SANITY CHECKS
--
--  1) THE ONE THAT MATTERS. Targeting must still work. Post a note for one
--     student, then read the portal as a DIFFERENT student at the same school:
--       insert into public.announcements(business_id, title, card_id)
--       values ('<YOUR BIZ>', 'Private note', '<CARD A>');
--       select public.get_student_card('<CARD B CODE>','<CARD B PIN>')::text
--                like '%Private note%';        -- must be FALSE
--       select public.get_student_card('<CARD A CODE>','<CARD A PIN>')::text
--                like '%Private note%';        -- must be TRUE
--     If B can see it, roll back immediately by re-running the
--     get_student_card block from migration-announcement-targeting.sql.
--     Clean up:  delete from public.announcements where title = 'Private note';
--
--  2) the icon now reaches a student
--       select public.get_student_card('<CODE>','<PIN>') -> 'business' -> 'icon';
--     Null before you pick one in Settings -> Appearance -> Icon; your chosen
--     icon after.
--
--  3) the icon reaches a parent. Signed in as a parent in the app, the school's
--     icon on their card should match what the owner picked.
--
--  ROLLBACK: re-run the get_my_cards block from
--  migration-business-accent-part-b.sql and the get_student_card block from
--  migration-announcement-targeting.sql. Both return the functions to exactly
--  what they were before this file; the businesses.icon column can stay, since
--  nothing else reads it.
-- ============================================================================
