-- ============================================================================
--  Migration: announcements can be addressed to a class, or to one student
--  ----------------------------------------------------------------------------
--  Today an announcement has only business_id, so every note goes to every
--  family at the school. "Sharks moves to Thursday" reaches parents whose
--  child is not in Sharks, who then have to work out whether it applies to
--  them — and a note meant for one family has nowhere to go at all.
--
--  A note now has at most ONE target:
--
--      group_id null, card_id null   the whole school   (what every existing
--                                                        row already is)
--      group_id set                  one class
--      card_id  set                  one student
--
--  Per class rather than per child is the unit that matches how a school
--  thinks — it teaches classes, not other people's children — and it lands
--  per child anyway, because every card carries a group_id.
--
--  ----------------------------------------------------------------------------
--  THE COLUMNS AND THE READ PATHS MUST SHIP TOGETHER
--
--  get_student_card returns every announcement for the business. Add the
--  columns without changing it and the first note addressed to one student is
--  visible to every student at that school, code and PIN being all it takes.
--  That is why this migration does both in one file rather than staging them.
--
--  ----------------------------------------------------------------------------
--  VERIFY BEFORE RUNNING
--
--  The two functions below are recreated in full. Their bodies were taken from
--  a PostgreSQL replica built from schema.sql, every committed migration, and
--  the recovered live definitions in migration-business-accent-part-b.sql — not
--  retyped. This repo's SQL has been behind the live database twice before, so
--  dump what is actually running and compare before you run this:
--
--    select p.proname, pg_get_functiondef(p.oid)
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('get_my_announcements', 'get_student_card');
--
--  Every line below should be one you recognise, apart from the blocks marked
--  <-- TARGETING.
--
--  Run ONCE in the Supabase SQL editor.
-- ============================================================================


-- ---------------------------------------------------------------------------
--  1. The target
--
--      Both cascade rather than set null. A class note whose class is deleted
--      would otherwise silently become a school-wide note, and a note written
--      for one student would become a note for everyone — the wrong direction
--      to fail in, on a message somebody has already read.
-- ---------------------------------------------------------------------------
alter table public.announcements
  add column if not exists group_id uuid references public.groups(id) on delete cascade;
alter table public.announcements
  add column if not exists card_id  uuid references public.cards(id)  on delete cascade;

alter table public.announcements drop constraint if exists announcements_one_target;
alter table public.announcements
  add constraint announcements_one_target
  check (group_id is null or card_id is null);

comment on column public.announcements.group_id is
  'Class this note is for. Null with card_id null = the whole school.';
comment on column public.announcements.card_id is
  'Single student this note is for. Null with group_id null = the whole school.';

create index if not exists announcements_group_idx on public.announcements(group_id) where group_id is not null;
create index if not exists announcements_card_idx  on public.announcements(card_id)  where card_id  is not null;


-- ---------------------------------------------------------------------------
--  2. A target must belong to the same business
--
--      RLS only checks business_id, so nothing stops an owner writing a note
--      for their own school while pointing group_id at another school's class.
--      A check constraint cannot look at another table, so this is a trigger.
--      Without it the class tag on a note could name a class the reader's
--      school does not have.
-- ---------------------------------------------------------------------------
create or replace function public.announcements_check_target()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.group_id is not null and not exists (
       select 1 from public.groups g
        where g.id = new.group_id and g.business_id = new.business_id) then
    raise exception 'That class does not belong to this business';
  end if;
  if new.card_id is not null and not exists (
       select 1 from public.cards c
        where c.id = new.card_id and c.business_id = new.business_id) then
    raise exception 'That student does not belong to this business';
  end if;
  return new;
end;
$function$;

drop trigger if exists announcements_target_belongs on public.announcements;
create trigger announcements_target_belongs
  before insert or update on public.announcements
  for each row execute function public.announcements_check_target();


-- ---------------------------------------------------------------------------
--  3. The parent's feed
--
--      Unchanged apart from the block marked <-- TARGETING, plus the target
--      fields on the way out so the portal can label a note.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_announcements()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r record;
begin
  if v_email is null then return result; end if;
  for r in
    select a.id, a.business_id, a.title, a.body, a.image_url, a.is_pinned, a.created_at,
           b.name as b_name,
           a.group_id, a.card_id,                                  -- <-- TARGETING
           g.name  as g_name,                                      -- <-- TARGETING
           tc.name as c_name                                       -- <-- TARGETING
    from public.announcements a
    join public.businesses b on b.id = a.business_id
    left join public.groups g  on g.id  = a.group_id               -- <-- TARGETING
    left join public.cards  tc on tc.id = a.card_id                -- <-- TARGETING
    where a.is_active
      and (a.expires_at is null or a.expires_at > now())
      and a.business_id in (
        select c.business_id from public.card_links cl
        join public.cards c on c.id = cl.card_id
        where cl.parent_email = v_email)
      -- <-- TARGETING: school-wide, or aimed at one of this parent's own
      -- cards, or at a class one of their children is actually in. The
      -- business_id filter above still applies, so a target can never pull in
      -- a note from a school this parent has no card at.
      and (
        (a.group_id is null and a.card_id is null)
        or a.card_id in (
             select cl.card_id from public.card_links cl
              where cl.parent_email = v_email)
        or a.group_id in (
             select c.group_id from public.card_links cl
             join public.cards c on c.id = cl.card_id
              where cl.parent_email = v_email and c.group_id is not null)
      )
    order by a.is_pinned desc, a.created_at desc
  loop
    result := result || jsonb_build_object(
      'id', r.id, 'business_id', r.business_id, 'business_name', r.b_name,
      'title', r.title, 'body', r.body, 'image_url', r.image_url,
      'is_pinned', r.is_pinned, 'created_at', r.created_at,
      -- <-- TARGETING: 'all' | 'group' | 'student', and what to call it.
      'target_kind', case when r.card_id is not null then 'student'
                          when r.group_id is not null then 'group'
                          else 'all' end,
      'target_name', coalesce(r.c_name, r.g_name),
      'group_id', r.group_id, 'card_id', r.card_id);
  end loop;
  return result;
end;
$$;
revoke all on function public.get_my_announcements() from public, anon;
grant execute on function public.get_my_announcements() to authenticated;


-- ---------------------------------------------------------------------------
--  4. The student's own view
--
--      The same filter, from the other end: this student's card, this
--      student's class, or the whole school. This is the one that matters for
--      privacy — without it a note written for one student is readable by
--      every student at the school.
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
                                 else 'all' end,                   -- <-- TARGETING
             'target_name', coalesce(tc.name, g2.name))            -- <-- TARGETING
             order by a.is_pinned desc, a.created_at desc),
           '[]'::jsonb)
    into v_ann
    from public.announcements a
    left join public.groups g2 on g2.id = a.group_id               -- <-- TARGETING
    left join public.cards tc  on tc.id = a.card_id                -- <-- TARGETING
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

revoke all on function public.get_student_card(text,text) from public;
grant execute on function public.get_student_card(text,text) to anon, authenticated;


-- ============================================================================
--  SANITY CHECKS
--
--  1) every existing announcement is untouched and still school-wide
--       select count(*) as total,
--              count(group_id) as class_notes,
--              count(card_id)  as student_notes
--         from public.announcements;      -- class_notes and student_notes = 0
--
--  2) a target from another school is refused. Replace the ids with a group
--     belonging to a DIFFERENT business than the announcement:
--       insert into public.announcements(business_id, title, group_id)
--       values ('<YOUR BIZ>', 'should fail', '<OTHER BIZ GROUP>');
--     Expect: "That class does not belong to this business".
--
--  3) both targets at once is refused
--       insert into public.announcements(business_id, title, group_id, card_id)
--       values ('<YOUR BIZ>', 'should fail', '<GROUP>', '<CARD>');
--     Expect: violates check constraint "announcements_one_target".
--
--  4) THE ONE THAT MATTERS. Post a note for one student, then read the portal
--     as a DIFFERENT student at the same school and confirm it is absent:
--       insert into public.announcements(business_id, title, card_id)
--       values ('<YOUR BIZ>', 'Private note', '<CARD A>');
--       select jsonb_array_length(
--                public.get_student_card('<CARD B CODE>', '<CARD B PIN>')
--                -> 'announcements');
--     Then check card A does see it. If B sees it, stop and tell me.
--
--  CLEAN UP after testing:
--       delete from public.announcements where title in ('should fail','Private note');
--
--  ROLLBACK (returns announcements to school-wide only):
--       drop trigger if exists announcements_target_belongs on public.announcements;
--       drop function if exists public.announcements_check_target();
--       alter table public.announcements drop constraint if exists announcements_one_target;
--       alter table public.announcements drop column if exists group_id;
--       alter table public.announcements drop column if exists card_id;
--     then re-run the get_my_announcements block from migration-announcements.sql
--     and the get_student_card block from migration-business-accent-part-b.sql.
-- ============================================================================
