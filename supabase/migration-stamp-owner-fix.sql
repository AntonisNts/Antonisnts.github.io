-- ===========================================================================
--  An owner pressing their own stamp gets an answer
--  -------------------------------------------------------------------------
--  stamp_begin_geometry has an owner branch -- "this is the school's own
--  device, nothing recorded" -- matching what the tag path gives. It was
--  unreachable.
--
--  It sat INSIDE the loop over the caller's card_links, and a school owner has
--  no card_links: those rows link a PARENT to a child. So the loop never ran a
--  single iteration for an owner, the branch never executed, and pressing your
--  own stamp on your own phone returned no_match -- which the app renders as
--  nothing at all, because a non-match is deliberately silent.
--
--  The effect was a school owner testing their stamp, seeing nothing happen,
--  and having no way to tell a working stamp from a broken calibration.
--
--  Found by the test rig rather than by reading: the assertion that covered it
--  returned NULL rather than false, and run-tests.sh counted only t and f, so
--  it was neither passing nor failing. It was simply absent. The counter now
--  treats a NULL verdict as a failure, which is what surfaced this.
--
--  Replaces one function. Safe to re-run.
-- ===========================================================================

create or replace function public.stamp_begin_geometry(p_points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.email();
  v_uid   uuid := auth.uid();
  n       int;
  r       record;
  s       numeric;
  bestBiz uuid := null;
  bestS   numeric := null;
  tied    boolean := false;
  v_own   public.businesses%rowtype;
  v_g     public.stamp_geometries%rowtype;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    return jsonb_build_object('error', 'no_match');
  end if;
  n := jsonb_array_length(p_points);
  if n < 4 or n > 8 then
    return jsonb_build_object('error', 'no_match');
  end if;

  -- The owner's own device, checked BEFORE anything to do with card_links --
  -- which is the whole fix. An owner has no linked children, so anything that
  -- depends on that loop can never see them.
  select * into v_own from public.businesses where owner_id = v_uid limit 1;
  if found then
    select * into v_g from public.stamp_geometries where business_id = v_own.id;
    if found and public.stamp_geometry_match(p_points, v_g.points, v_g.tolerance) is not null then
      return jsonb_build_object('owner', true, 'business_name', v_own.name);
    end if;
  end if;

  for r in
    select distinct g.business_id, g.points, g.tolerance
      from public.card_links cl
      join public.cards c            on c.id = cl.card_id
      join public.stamp_geometries g on g.business_id = c.business_id
     where cl.parent_email = v_email
  loop
    s := public.stamp_geometry_match(p_points, r.points, r.tolerance);
    if s is not null then
      if bestS is null or s < bestS then
        bestS := s; bestBiz := r.business_id; tied := false;
      elsif s = bestS then
        tied := true;
      end if;
    end if;
  end loop;

  if bestBiz is null or tied then
    return jsonb_build_object('error', 'no_match');
  end if;

  return public.stamp_open_session(bestBiz, v_email, 'stamp');
end;
$$;

revoke all on function public.stamp_begin_geometry(jsonb) from public, anon;
grant execute on function public.stamp_begin_geometry(jsonb) to authenticated;

-- ===========================================================================
--  ROLLBACK: re-run migration-stamp-geometry.sql.
-- ===========================================================================
