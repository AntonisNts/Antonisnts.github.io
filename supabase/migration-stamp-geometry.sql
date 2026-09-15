-- ===========================================================================
--  Stamp trigger  (Part 3)
--  -------------------------------------------------------------------------
--  A rubber stamp with conductive pads is pressed against the parent's screen.
--  The browser sees several simultaneous touches, and the pattern those points
--  make identifies the school.
--
--  WHERE THE MATCHING HAPPENS IS THE WHOLE SECURITY QUESTION. It happens here,
--  not in the browser. If the page decided which business matched and sent an
--  id, any parent could open a confirmation from their sofa and the physical
--  stamp would be protecting nothing -- the same trap as accepting a payments
--  blob in stamp_confirm. The browser sends raw points and learns only whether
--  something matched.
--
--  A geometry is only ever compared against schools the caller is already a
--  customer of. Comparing against every school would turn this into an oracle
--  for reading other schools' stamp patterns.
--
--  Be clear-eyed about what this is worth: a stamp pattern is five points on a
--  physical object, visible to anyone who looks at it and reproducible with
--  five fingers. It is the WEAKEST of the three triggers -- weaker than a
--  24-character token on a tag. That is inherent to the mechanism, not a fault
--  in this implementation, and it is why require_pin_on_confirm exists.
--
--  Additive and idempotent. One new table. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. The registered geometry, one per school
--
--  Stored as captured: absolute CSS-pixel coordinates from the calibration
--  press. The normalising happens at match time, because which point is
--  leftmost depends on how the stamp landed.
--
--  device_ratio is recorded but NOT used for matching. It is here so that when
--  a cross-device mismatch is eventually investigated, the calibration device
--  is known rather than guessed at. See the note on limits at the bottom.
-- ---------------------------------------------------------------------------

create table if not exists public.stamp_geometries (
  business_id  uuid primary key references public.businesses(id) on delete cascade,
  points       jsonb   not null,
  tolerance    numeric not null default 18 check (tolerance > 0 and tolerance <= 60),
  device_ratio numeric,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table public.stamp_geometries enable row level security;
revoke all on table public.stamp_geometries from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  2. Matching
--
--  The captured points arrive already normalised against their own leftmost
--  point, so contact order does not matter. But the stamp may have more pads
--  than the browser reported -- iOS gives at most five touches however many
--  pads are pressed -- so the captured set is a SUBSET of the stored one, and
--  its leftmost point is not necessarily the stored leftmost.
--
--  Hence: try every stored point as the anchor. For each, translate the stored
--  set so that point sits at the origin, then greedily pair each captured
--  point with its nearest unused stored point. A pairing where every point
--  lands within tolerance is a match, and the score is the worst pair in it.
--  The best anchor wins, which is what "best subset" means here.
--
--  Returns the score, or null for no match. Lower is better.
--
--  Deliberately NOT handled: rotation. The stamp is assumed to land roughly
--  square to the screen, which is what the capture design assumes too. A
--  rotated press will simply not match, and that is the first thing to check
--  if real-device testing shows misses.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_geometry_match(
  p_captured jsonb, p_stored jsonb, p_tol numeric)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
  nc int := jsonb_array_length(p_captured);
  ns int := jsonb_array_length(p_stored);
  cx numeric[]; cy numeric[];
  sx numeric[]; sy numeric[];
  used boolean[];
  a int; i int; j int;
  ax numeric; ay numeric;
  bestJ int; bestD numeric; d numeric;
  worst numeric; okAll boolean;
  score numeric := null;
begin
  if nc < 4 or ns < nc then return null; end if;

  for i in 0..nc-1 loop
    cx[i] := (p_captured->i->>0)::numeric;
    cy[i] := (p_captured->i->>1)::numeric;
  end loop;
  for i in 0..ns-1 loop
    sx[i] := (p_stored->i->>0)::numeric;
    sy[i] := (p_stored->i->>1)::numeric;
  end loop;

  for a in 0..ns-1 loop
    ax := sx[a]; ay := sy[a];
    used := array_fill(false, array[ns]);
    worst := 0; okAll := true;

    for i in 0..nc-1 loop
      bestJ := -1; bestD := null;
      for j in 0..ns-1 loop
        if used[j+1] then continue; end if;
        d := sqrt(power((sx[j]-ax) - cx[i], 2) + power((sy[j]-ay) - cy[i], 2));
        if bestD is null or d < bestD then bestD := d; bestJ := j; end if;
      end loop;
      if bestJ < 0 or bestD > p_tol then okAll := false; exit; end if;
      used[bestJ+1] := true;
      if bestD > worst then worst := bestD; end if;
    end loop;

    if okAll and (score is null or worst < score) then score := worst; end if;
  end loop;

  return score;
end;
$$;


-- ===========================================================================
--  3. Owner side: calibration
-- ===========================================================================

create or replace function public.stamp_geometry_get()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz public.businesses%rowtype;
  g     public.stamp_geometries%rowtype;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then return jsonb_build_object('error', 'no_business'); end if;

  select * into g from public.stamp_geometries where business_id = v_biz.id;
  if not found then
    return jsonb_build_object('ok', true, 'calibrated', false);
  end if;

  -- The points themselves go back to the owner: it is their own stamp, and the
  -- calibration screen draws them so a bad capture can be seen and redone.
  return jsonb_build_object(
    'ok', true, 'calibrated', true,
    'points', g.points,
    'point_count', jsonb_array_length(g.points),
    'tolerance', g.tolerance,
    'updated_at', g.updated_at);
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_geometry_set -- register or re-register. Upsert, so re-calibrating is
--  the same call; there is no separate "replace" path to get wrong.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_geometry_set(
  p_points jsonb, p_tolerance numeric default 18, p_ratio numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz public.businesses%rowtype;
  n     int;
  i     int;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then return jsonb_build_object('error', 'no_business'); end if;

  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    return jsonb_build_object('error', 'bad_points');
  end if;
  n := jsonb_array_length(p_points);
  -- Four is the floor the trigger will attempt to match on, so a calibration
  -- with fewer could never be matched. Eight is a sanity ceiling: no stamp has
  -- that many pads, and a bigger array is a runaway capture.
  if n < 4 or n > 8 then
    return jsonb_build_object('error', 'bad_count', 'count', n);
  end if;
  for i in 0..n-1 loop
    if jsonb_typeof(p_points->i) <> 'array'
       or jsonb_array_length(p_points->i) <> 2
       or (p_points->i->>0) is null or (p_points->i->>1) is null then
      return jsonb_build_object('error', 'bad_points');
    end if;
  end loop;
  if p_tolerance is null or p_tolerance <= 0 or p_tolerance > 60 then
    return jsonb_build_object('error', 'bad_tolerance');
  end if;

  insert into public.stamp_geometries(business_id, points, tolerance, device_ratio)
    values (v_biz.id, p_points, p_tolerance, p_ratio)
  on conflict (business_id) do update
    set points = excluded.points,
        tolerance = excluded.tolerance,
        device_ratio = excluded.device_ratio,
        updated_at = now();

  return jsonb_build_object('ok', true, 'point_count', n);
end;
$$;


create or replace function public.stamp_geometry_clear()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_biz public.businesses%rowtype;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then return jsonb_build_object('error', 'no_business'); end if;
  delete from public.stamp_geometries where business_id = v_biz.id;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  4. The session, extracted so there is exactly one of it
-- ===========================================================================
--
--  stamp_begin already knew how to open a confirmation session and build the
--  student list. The stamp trigger needs precisely that and nothing else, so
--  it is lifted out here rather than copied. stamp_begin below is rewritten to
--  call it, which is the point: one implementation, three ways in.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_open_session(
  p_biz_id uuid, p_email text, p_trigger text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz      public.businesses%rowtype;
  v_conf     uuid;
  v_exp      timestamptz;
  v_year     int;
  v_students jsonb := '[]'::jsonb;
  r          record;
  v_first    record;
  v_skip     int[];
  v_amt      numeric;
  v_label    text;
begin
  select * into v_biz from public.businesses where id = p_biz_id;
  if not found then return jsonb_build_object('error', 'no_match'); end if;
  v_year := v_biz.year;

  delete from public.stamp_confirmations where created_at < now() - interval '1 day';

  for r in
    select c.id, c.name, c.level, c.payments, c.fee_history,
           c.enrollment_start_month, c.paused_months
      from public.card_links cl
      join public.cards c on c.id = cl.card_id
     where cl.parent_email = p_email
       and c.business_id   = v_biz.id
     order by c.name
  loop
    v_skip := (
      select coalesce(array_agg(x::int), '{}')
        from (
          select jsonb_array_elements_text(coalesce(v_biz.inactive_months, '[]'::jsonb)) as x
          union all
          select jsonb_array_elements_text(coalesce(r.paused_months, '[]'::jsonb))
        ) s);

    select b.mi, b.applying
      into v_first
      from public.stamp_calc_breakdown(
             coalesce(r.payments,'{}'::jsonb), 999999, v_year, v_skip,
             r.enrollment_start_month, r.level, r.fee_history, v_biz.fee) b
     order by b.mi limit 1;

    if not found then
      v_amt := 0; v_label := null;
    else
      v_amt   := greatest(v_first.applying, 0);
      v_label := (array['January','February','March','April','May','June','July',
                        'August','September','October','November','December'])[v_first.mi + 1];
    end if;

    v_students := v_students || jsonb_build_object(
      'card_id', r.id, 'name', r.name, 'amount', v_amt, 'month', v_label);
  end loop;

  if jsonb_array_length(v_students) = 0 then
    return jsonb_build_object('error', 'no_match');
  end if;

  v_exp := now() + interval '60 seconds';
  insert into public.stamp_confirmations(business_id, parent_email, trigger_source, expires_at)
    values (v_biz.id, p_email, p_trigger, v_exp)
    returning id into v_conf;

  return jsonb_build_object(
    'ok',            true,
    'confirmation',  v_conf,
    'expires_at',    v_exp,
    'trigger',       p_trigger,
    'require_pin',   v_biz.require_pin_on_confirm,
    'business_name', v_biz.name,
    'type',          v_biz.type,
    'accent',        v_biz.accent,
    'icon',          v_biz.icon,
    'year',          v_year,
    'students',      v_students);
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_begin, rewritten over the shared session. Behaviour is unchanged --
--  the existing suite is what says so.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_begin(p_token text, p_nonce text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.email();
  v_uid     uuid := auth.uid();
  v_tok     public.stamp_tokens%rowtype;
  v_biz     public.businesses%rowtype;
  v_trigger text;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  select * into v_tok from public.stamp_tokens
   where token = p_token and revoked_at is null limit 1;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  select * into v_biz from public.businesses where id = v_tok.business_id;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  if v_biz.owner_id = v_uid then
    return jsonb_build_object('owner', true, 'business_name', v_biz.name);
  end if;

  v_trigger := case when public.stamp_nonce_valid(p_token, p_nonce) then 'qr' else 'nfc' end;
  return public.stamp_open_session(v_biz.id, v_email, v_trigger);
end;
$$;


-- ===========================================================================
--  5. stamp_begin_geometry -- the stamp trigger's way in
-- ===========================================================================
--
--  Only schools this caller is a customer of are considered, and only ones
--  that have registered a geometry. The best-scoring school wins; a tie is
--  resolved by taking neither, because two schools whose stamps are
--  indistinguishable is a situation to notice rather than guess at.
--
--  Every failure returns the same 'no_match'. The page does nothing silently
--  on that, so nothing here leaks whether a school has a stamp registered,
--  whether it nearly matched, or how far off it was.
-- ---------------------------------------------------------------------------

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

  for r in
    select distinct g.business_id, g.points, g.tolerance, b.owner_id
      from public.card_links cl
      join public.cards c           on c.id = cl.card_id
      join public.stamp_geometries g on g.business_id = c.business_id
      join public.businesses b       on b.id = g.business_id
     where cl.parent_email = v_email
  loop
    -- An owner pressing their own stamp on their own phone is testing it.
    -- Same answer as the tag gives, for the same reason.
    if r.owner_id = v_uid then
      return jsonb_build_object('owner', true,
        'business_name', (select name from public.businesses where id = r.business_id));
    end if;

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


-- ===========================================================================
--  6. Grants
-- ===========================================================================

revoke all on function public.stamp_geometry_match(jsonb,jsonb,numeric)  from public, anon;
revoke all on function public.stamp_open_session(uuid,text,text)         from public, anon;
revoke all on function public.stamp_geometry_get()                       from public, anon;
revoke all on function public.stamp_geometry_set(jsonb,numeric,numeric)  from public, anon;
revoke all on function public.stamp_geometry_clear()                     from public, anon;
revoke all on function public.stamp_begin_geometry(jsonb)                from public, anon;

grant execute on function public.stamp_geometry_get()                      to authenticated;
grant execute on function public.stamp_geometry_set(jsonb,numeric,numeric) to authenticated;
grant execute on function public.stamp_geometry_clear()                    to authenticated;
grant execute on function public.stamp_begin_geometry(jsonb)               to authenticated;

-- stamp_geometry_match and stamp_open_session are internal. stamp_open_session
-- in particular takes a business id and opens a session against it with NO
-- checks of its own -- every caller above does the checking. Granting it would
-- hand any logged-in parent a confirmation for any school they can name.


-- ===========================================================================
--  KNOWN LIMITS, recorded here because they are the things to test on real
--  hardware rather than reason about:
--
--   1. Screen density. Coordinates are CSS pixels, and the calibration is done
--      on the OWNER's device while matching happens on a PARENT's. iPhones sit
--      near 163 CSS px/inch so iPhone-to-iPhone should be close, but an Android
--      at a different density will read the same physical stamp at a different
--      size and miss. Widening the tolerance trades that against false matches.
--
--   2. Rotation. Not handled, by design (see stamp_geometry_match).
--
--   3. iOS reports at most five touches. That is why matching is subset-based
--      and why the floor is four rather than an exact count.
--
--  ROLLBACK
--    drop function if exists public.stamp_begin_geometry(jsonb);
--    drop function if exists public.stamp_geometry_clear();
--    drop function if exists public.stamp_geometry_set(jsonb,numeric,numeric);
--    drop function if exists public.stamp_geometry_get();
--    drop function if exists public.stamp_geometry_match(jsonb,jsonb,numeric);
--    drop table if exists public.stamp_geometries;
--    -- stamp_begin keeps working; re-run migration-stamp-confirm.sql to
--    -- restore its self-contained form and drop stamp_open_session.
-- ===========================================================================
