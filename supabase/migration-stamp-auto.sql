-- ===========================================================================
--  "Does this person's school use a stamp?"
--  -------------------------------------------------------------------------
--  The stamp trigger shipped behind a per-device flag: a phone only listened
--  after being opened once with ?stamptrigger=1. That was right for building
--  it and wrong for using it. A parent at the desk has their own phone, that
--  phone has never seen the flag, and telling every parent to paste a URL is
--  not a thing that happens in a queue.
--
--  So the app asks instead. One question, once, when it loads: does any school
--  this person deals with have a stamp registered? Only then does it listen.
--
--  Two functions rather than one because the two portals prove identity in
--  completely different ways -- an account in one, a share code and PIN in the
--  other. Neither returns anything about the pattern itself: the answer is a
--  single boolean, and the matching stays where it was.
--
--  Additive. Two read-only functions. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  stamp_trigger_active -- for the family portal.
--
--  True when any school the caller has a child at has calibrated a stamp. It
--  reveals nothing a parent could not already find out by pressing something
--  against the screen, and it is the cheapest possible version of that
--  question: existence only, no geometry, no school named.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_trigger_active()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_email text := auth.email();
begin
  if v_email is null then
    return jsonb_build_object('active', false);
  end if;

  return jsonb_build_object('active', exists (
    select 1
      from public.card_links cl
      join public.cards c            on c.id = cl.card_id
      join public.stamp_geometries g on g.business_id = c.business_id
     where cl.parent_email = v_email));
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_trigger_active_student -- for the Quick View portal, which has no
--  login. The code and PIN are checked the same way every other student-portal
--  function checks them, under the same rate limit, so this cannot be used to
--  probe which schools use a stamp without already holding a valid card.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_trigger_active_student(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then
    return jsonb_build_object('active', false);
  end if;
  return jsonb_build_object('active', exists (
    select 1 from public.stamp_geometries where business_id = c.business_id));
end;
$$;


-- ===========================================================================
--  Grants
-- ===========================================================================

revoke all on function public.stamp_trigger_active()                  from public, anon;
revoke all on function public.stamp_trigger_active_student(text,text) from public;

grant execute on function public.stamp_trigger_active()                  to authenticated;
grant execute on function public.stamp_trigger_active_student(text,text) to anon, authenticated;


-- ===========================================================================
--  ROLLBACK
--    drop function if exists public.stamp_trigger_active_student(text,text);
--    drop function if exists public.stamp_trigger_active();
--    -- the app then falls back to its manual flag, which still works.
-- ===========================================================================
