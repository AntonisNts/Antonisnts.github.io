-- ============================================================================
--  Migration: owner-chosen accent colour  (PART B of B)
--  ----------------------------------------------------------------------------
--  Part A added businesses.accent. This carries it through the two parent- and
--  student-facing readers, so a school's chosen colour reaches the family
--  portal and the student view. Part A must be run first.
--
--  NO FRONTEND CHANGE IS NEEDED. app/index.html already reads the field in
--  both mappers (accent:e.business.accent||null in loadMyCards, and
--  accent:b.accent||null in the student PIN reader), so the colour flows the
--  moment these functions return it.
--
--  ----------------------------------------------------------------------------
--  IMPORTANT - THIS FILE IS ALSO A RECOVERY.
--
--  The definitions below were dumped from the LIVE database with
--  pg_get_functiondef(), not reconstructed from this repo. The repo was out of
--  date: the groups/teachers work of June 2026 was pasted straight into the
--  Supabase SQL editor and never committed, so the newest copies of these two
--  functions in supabase/ (migration-flip-card.sql) know nothing about
--  public.groups, public.teachers, or the inline 'group' object the parent
--  portal and student view both render. Re-creating either function from those
--  files would have silently dropped group and teacher support.
--
--  Everything below is the live definition VERBATIM, reformatted for reading,
--  with exactly two additions, both marked "<-- PART B":
--    get_my_cards()     : b.accent as b_accent in the select list,
--                         'accent', r.b_accent in the business object
--    get_student_card() : 'accent', b.accent in the business object
--                         (b is a businesses%rowtype, so no select change)
--
--  Run ONCE in the Supabase SQL editor, AFTER Part A.
-- ============================================================================


-- ---------------------------------------------------------------------------
--  get_my_cards() - the family portal reader
-- ---------------------------------------------------------------------------
create or replace function public.get_my_cards()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r       record;
begin
  if v_email is null then return result; end if;

  for r in
    select c.id, c.name, c.level, c.share_code, c.payments, c.history,
           c.enrollment_start_month, c.paused_months, c.fee_history,
           c.group_name, c.lesson_schedule, c.group_id, cl.child_id,
           g.name        as g_name,
           g.schedule    as g_schedule,
           g.teacher_id  as g_teacher_id,
           t.name        as g_teacher_name,
           b.name        as b_name,
           b.type        as b_type,
           b.fee         as b_fee,
           b.year        as b_year,
           b.biz_code    as b_code,
           b.inactive_months    as b_inactive,
           b.levels             as b_levels,
           b.custom_card_image  as b_image,
           b.accent             as b_accent          -- <-- PART B
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
        'levels', r.b_levels, 'custom_card_image', r.b_image,
        'accent', r.b_accent)                        -- <-- PART B
    );
  end loop;

  return result;
end;
$function$;


-- ---------------------------------------------------------------------------
--  get_student_card(text, text) - the anonymous code + PIN reader
-- ---------------------------------------------------------------------------
create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
             'created_at', a.created_at)
             order by a.is_pinned desc, a.created_at desc),
           '[]'::jsonb)
    into v_ann
    from public.announcements a
   where a.business_id = b.id
     and a.is_active
     and (a.expires_at is null or a.expires_at > now());

  return jsonb_build_object(
    'business', jsonb_build_object(
      'name', b.name, 'type', b.type, 'fee', b.fee, 'year', b.year,
      'biz_code', b.biz_code, 'inactive_months', b.inactive_months,
      'levels', b.levels, 'custom_card_image', b.custom_card_image,
      'accent', b.accent),                           -- <-- PART B
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

-- create or replace preserves existing privileges, but the signatures are
-- unchanged and re-granting is free, so state them explicitly the way every
-- other migration in this repo does.
grant execute on function public.get_my_cards()                to authenticated;
grant execute on function public.get_student_card(text, text)  to anon, authenticated;

-- ============================================================================
--  Done. No table, column, policy or row was touched - only two function
--  bodies were replaced.
--
--  Sanity checks. Use a REAL student code + PIN from your dashboard; a correct
--  pair leaves no trace (a wrong one records a throttling attempt):
--
--    -- 1) the colour now reaches the student view
--    select public.get_student_card('YOURCODE','1234') -> 'business' -> 'accent';
--       -- null before an owner picks a colour, then e.g. "mint"
--
--    -- 2) THE REGRESSION THAT MATTERS: groups must still be there.
--    --    Use a student who is assigned to a group.
--    select public.get_student_card('YOURCODE','1234') -> 'card' -> 'group';
--       -- expect {"id":..., "name":"...", "schedule":[...],
--       --         "teacher_id":..., "teacher_name":"..."}
--       -- if this is null for a student who IS in a group, STOP and tell me.
--
--    -- 3) get_my_cards needs a logged-in parent, so check it in the app:
--    --    open the family portal, confirm the school's colour shows and that
--    --    the flipped card still lists the group name and lesson schedule.
--
--  ROLLBACK: re-run this file with the two "<-- PART B" lines deleted. That
--  restores the exact definitions that were live before it.
-- ============================================================================
