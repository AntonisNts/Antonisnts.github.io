-- ===========================================================================
--  Any-angle stamp matching
--  -------------------------------------------------------------------------
--  Real-device testing found what the first version's comments predicted: the
--  stamp only matched when pressed at the same angle it was calibrated at.
--  Nobody presses a stamp that carefully, and a competitor's does not ask them
--  to, so it is not a limitation to document -- it is the feature missing.
--
--  The old matcher allowed translation only: it slid the stored pattern around
--  until the points lined up. This one solves for a SIMILARITY transform --
--  translation, rotation, and a bounded change of scale -- from every pair of
--  points that could plausibly correspond, and keeps the best fit.
--
--  Allowing scale is not scope creep, it is the same fix. The pattern is
--  measured in screen pixels and calibrated on the OWNER's phone while it is
--  matched on a PARENT's, so the same physical stamp reads at a different size
--  on a different handset. That was the other limitation recorded at the foot
--  of migration-stamp-geometry.sql, and solving for scale retires it too.
--
--  Two points fix a similarity transform exactly, which is why the search is
--  over pairs. What stops that from matching anything against anything is that
--  every REMAINING point must then land within tolerance, and that a nearly
--  straight line of contacts is refused outright.
--
--  Replaces one function. No table changes. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  Bounds, named rather than buried in the arithmetic.
--
--  Scale is deliberately narrow. Wide enough for the spread of phone screen
--  densities, narrow enough that a small tight cluster of fingers cannot be
--  stretched onto a large stamp.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_match_bounds()
returns table (scale_min numeric, scale_max numeric, min_baseline numeric, min_spread numeric)
language sql immutable set search_path = public as $$
  select 0.75::numeric, 1.34::numeric, 12::numeric, 0.12::numeric;
$$;


-- ---------------------------------------------------------------------------
--  stamp_geometry_match -- same signature, same contract: the best score, or
--  null for no match. Lower is better, and it is still the worst-placed point
--  of the winning fit, measured in captured pixels.
--
--  The search:
--
--    - Take the captured points' longest few baselines. Longest first because
--      a short baseline turns a small positional error into a large angular
--      one, and the whole transform then swings.
--    - For every ordered pair of stored points, ask what rotation and scale
--      would carry that pair onto the captured baseline. Reject it out of hand
--      if the implied scale is outside the bounds -- that prunes most of the
--      search before any distance is computed.
--    - Apply the transform to every stored point, pair each captured point
--      with its nearest unused one, and keep the fit if every pair lands
--      inside tolerance.
--
--  Both orientations of each baseline are tried, because which of the two
--  points corresponds to which is exactly what is unknown.
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
  ci int; cj int; si int; sj int; t int; w int;
  ax numeric; ay numeric;                      -- the captured baseline anchor
  vcx numeric; vcy numeric; dc numeric;
  vsx numeric; vsy numeric; ds numeric;
  k numeric; cosT numeric; sinT numeric;
  qx numeric; qy numeric;
  bestIdx int; bestD numeric; d numeric;
  worst numeric; okAll boolean;
  score numeric := null;
  bi int[] := '{}'; bj int[] := '{}'; bd numeric[] := '{}';   -- baselines
  nbl int := 0;
  off numeric; maxOff numeric; v_span numeric; v_tol numeric;
  -- v_ prefixed because stamp_match_bounds() returns columns of these names,
  -- and an unprefixed local collides with them -- a collision Postgres only
  -- raises when the function is CALLED, never when it is created.
  v_smin numeric; v_smax numeric; v_base numeric; v_spread numeric;
begin
  if nc < 4 or ns < nc then return null; end if;

  select scale_min, scale_max, min_baseline, min_spread
    into v_smin, v_smax, v_base, v_spread
    from public.stamp_match_bounds();

  for ci in 0..nc-1 loop
    cx[ci] := (p_captured->ci->>0)::numeric;
    cy[ci] := (p_captured->ci->>1)::numeric;
  end loop;
  for si in 0..ns-1 loop
    sx[si] := (p_stored->si->>0)::numeric;
    sy[si] := (p_stored->si->>1)::numeric;
  end loop;

  -- Every captured baseline, longest first. Insertion into a list of at most
  -- three -- small enough that sorting it properly would be more code than it
  -- is worth, and the ordering is what matters, not the speed.
  for ci in 0..nc-2 loop
    for cj in ci+1..nc-1 loop
      d := sqrt(power(cx[cj]-cx[ci],2) + power(cy[cj]-cy[ci],2));
      if d < v_base then continue; end if;
      w := 1;
      while w <= nbl and bd[w] >= d loop w := w + 1; end loop;
      if w <= 3 then
        bi := (bi[1:w-1] || ci) || bi[w:3];
        bj := (bj[1:w-1] || cj) || bj[w:3];
        bd := (bd[1:w-1] || d)  || bd[w:3];
        nbl := least(nbl + 1, 3);
        bi := bi[1:3]; bj := bj[1:3]; bd := bd[1:3];
      end if;
    end loop;
  end loop;
  if nbl = 0 then return null; end if;

  -- A near-straight line of contacts is refused. Four fingers laid across a
  -- screen are collinear, and under free rotation and scale one line fits any
  -- other -- which would turn a hand resting on the phone into a payment.
  maxOff := 0;
  for ci in 0..nc-1 loop
    off := abs((cx[bj[1]]-cx[bi[1]]) * (cy[ci]-cy[bi[1]])
             - (cy[bj[1]]-cy[bi[1]]) * (cx[ci]-cx[bi[1]])) / bd[1];
    if off > maxOff then maxOff := off; end if;
  end loop;
  if maxOff < bd[1] * v_spread then return null; end if;

  -- Tolerance has to be relative to the pattern, not just absolute. 18px on a
  -- stamp spanning 60px is nearly a third of the whole shape, and measurement
  -- showed a DIFFERENT five-pad stamp fitting inside that at 16.6 while a
  -- genuine press scored 0-14. On a real stamp -- 3-5cm of glass, so 150-300px
  -- -- the absolute figure is the tighter of the two and this never binds.
  -- It only bites on small patterns, which are exactly the ones that need it.
  -- v_span is the pattern's longest diagonal, so 0.15 of it is roughly a
  -- fifth of a side -- tight enough to separate two different five-pad stamps.
  v_span := 0;
  for ci in 0..ns-2 loop
    for w in ci+1..ns-1 loop
      d := sqrt(power(sx[w]-sx[ci],2) + power(sy[w]-sy[ci],2));
      if d > v_span then v_span := d; end if;
    end loop;
  end loop;
  v_tol := least(p_tol, v_span * 0.15);

  for t in 1..nbl loop
    ax  := cx[bi[t]];  ay  := cy[bi[t]];
    vcx := cx[bj[t]] - ax;  vcy := cy[bj[t]] - ay;  dc := bd[t];

    -- Which stored point corresponds to which end of the baseline is exactly
    -- what is unknown, so every ordered pair is tried.
    for si in 0..ns-1 loop
      for sj in 0..ns-1 loop
        if si = sj then continue; end if;
        vsx := sx[sj]-sx[si]; vsy := sy[sj]-sy[si];
        ds := sqrt(power(vsx,2) + power(vsy,2));
        if ds < v_base then continue; end if;

        k := dc / ds;
        if k < v_smin or k > v_smax then continue; end if;

        -- The rotation carrying the stored vector onto the captured one,
        -- read straight off the dot and cross products. No trig required.
        cosT := (vcx*vsx + vcy*vsy) / (dc*ds);
        sinT := (vsx*vcy - vsy*vcx) / (dc*ds);

        used := array_fill(false, array[ns]);
        worst := 0; okAll := true;

        for ci in 0..nc-1 loop
          bestIdx := -1; bestD := null;
          for w in 0..ns-1 loop
            if used[w+1] then continue; end if;
            qx := k * (cosT*(sx[w]-sx[si]) - sinT*(sy[w]-sy[si])) + ax;
            qy := k * (sinT*(sx[w]-sx[si]) + cosT*(sy[w]-sy[si])) + ay;
            d := sqrt(power(qx-cx[ci],2) + power(qy-cy[ci],2));
            if bestD is null or d < bestD then bestD := d; bestIdx := w; end if;
          end loop;
          if bestIdx < 0 or bestD > v_tol then okAll := false; exit; end if;
          used[bestIdx+1] := true;
          if bestD > worst then worst := bestD; end if;
        end loop;

        if okAll and (score is null or worst < score) then
          score := worst;
          if score < 1 then return score; end if;   -- good enough to stop
        end if;
      end loop;
    end loop;
  end loop;

  return score;
end;
$$;

revoke all on function public.stamp_geometry_match(jsonb,jsonb,numeric) from public, anon;
revoke all on function public.stamp_match_bounds()                      from public, anon;

-- Both stay internal: stamp_begin_geometry is the only thing that should be
-- asking whether a pattern matches, because it is the only thing that also
-- checks WHOSE pattern it is allowed to ask about.


-- ===========================================================================
--  ROLLBACK
--    Re-run migration-stamp-geometry.sql to restore translation-only matching,
--    then: drop function if exists public.stamp_match_bounds();
-- ===========================================================================
