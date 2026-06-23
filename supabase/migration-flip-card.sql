-- ============================================================================
--  Migration: flippable card — lesson schedule + group name
--  Run ONCE in the Supabase SQL editor. Additive: two new columns on cards,
--  and get_my_cards()/get_student_card() re-created to also return them.
--  (Only 2 test students exist, so no data backfill concerns.)
-- ============================================================================

alter table public.cards
  add column if not exists lesson_schedule jsonb not null default '[]'::jsonb,
  add column if not exists group_name text;

-- get_my_cards: also return group_name + lesson_schedule -----------------------
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
           c.group_name, c.lesson_schedule, cl.child_id,
           b.name as b_name, b.type as b_type, b.fee as b_fee, b.year as b_year,
           b.biz_code as b_code, b.inactive_months as b_inactive,
           b.levels as b_levels, b.custom_card_image as b_image
    from public.card_links cl
    join public.cards c       on c.id = cl.card_id
    join public.businesses b  on b.id = c.business_id
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

-- get_student_card: also return group_name + lesson_schedule (keeps the
-- announcements array from the previous migration). -------------------------
create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v_fails int;
  c public.cards%rowtype;
  b public.businesses%rowtype;
  v_ann jsonb;
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
      'group_name', c.group_name, 'lesson_schedule', c.lesson_schedule),
    'announcements', v_ann
  );
end;
$$;
grant execute on function public.get_student_card(text, text) to anon, authenticated;

-- ============================================================================
--  Done. Sanity check:
--    select id, name, group_name, lesson_schedule from public.cards;
-- ============================================================================
