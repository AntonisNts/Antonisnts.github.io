-- Any-angle matching, and the stamp in the student portal.
-- Verdicts are the `pass` column: t or f. Run via ./run-tests.sh.
--
-- Two findings from real-device testing drive this file. The stamp only
-- matched when pressed at the angle it was calibrated at, and it did nothing
-- at all in the student portal. The first is a matching bug; the second was
-- never built, because that portal has no login for the old path to use.
--
-- Rotation invariance is the kind of change that makes a matcher MORE willing
-- to say yes, so most of what follows is about the things it must still
-- refuse.

\set ON_ERROR_STOP off

\echo '=== fixtures ==='
insert into auth.users(id,email) values
  ('70000000-0000-0000-0000-00000000000a','rot-owner@t.example'),
  ('70000000-0000-0000-0000-0000000000c0','rot-parent@t.example');

insert into public.businesses(id,owner_id,biz_code,name,type,fee,year,approval_status) values
  ('71000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-00000000000a','ROT-A','Rot School','Dance',50,2026,'approved');

insert into public.cards(id,business_id,name,share_code,pin,payments,history) values
  ('72000000-0000-0000-0000-0000000000ca','71000000-0000-0000-0000-000000000001','Rea','ROTREA','4321','{}','[]');

insert into public.card_links(card_id,parent_email) values
  ('72000000-0000-0000-0000-0000000000ca','rot-parent@t.example');

create or replace function pg_temp.act_as(p_uid text, p_email text) returns void
language sql as $$
  select set_config('request.jwt.claim.sub',   coalesce(p_uid,''),   false),
         set_config('request.jwt.claim.email', coalesce(p_email,''), false);
  select null::void;
$$;

-- Apply a rotation, a scale and an offset -- what a press of the same physical
-- stamp on a different phone, at a different angle, actually looks like.
create or replace function pg_temp.press(p jsonb, deg numeric, k numeric, dx numeric, dy numeric, noise numeric)
returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(
    round((k*((e->>0)::numeric*cos(radians(deg))::numeric - (e->>1)::numeric*sin(radians(deg))::numeric)
          + dx + (random()-0.5)*2*noise)::numeric, 2),
    round((k*((e->>0)::numeric*sin(radians(deg))::numeric + (e->>1)::numeric*cos(radians(deg))::numeric)
          + dy + (random()-0.5)*2*noise)::numeric, 2)))
  from jsonb_array_elements(p) e;
$$;

-- A realistic stamp: roughly 3cm of glass, so about 200 CSS pixels across.
\set STAMP '[[0,0],[200,0],[0,200],[200,200],[70,115]]'


\echo
\echo '=== A. any angle ==='

select 'a press at '||d||' degrees matches' as t,
       public.stamp_geometry_match(pg_temp.press(:'STAMP'::jsonb, d, 1, 400, 250, 0),
                                   :'STAMP'::jsonb, 18) is not null as pass
  from unnest(array[0,15,45,90,133,180,271,359]) d;

select 'and the fit is essentially exact, not merely inside tolerance' as t,
       public.stamp_geometry_match(pg_temp.press(:'STAMP'::jsonb, 47, 1, 400, 250, 0),
                                   :'STAMP'::jsonb, 18) < 0.01 as pass;

-- The other limitation the first version documented. Calibration happens on
-- the owner's phone and matching on a parent's, so the same stamp reads at a
-- different size; solving for scale retires that too.
select 'the same stamp on a denser screen ('||k||'x) still matches' as t,
       public.stamp_geometry_match(pg_temp.press(:'STAMP'::jsonb, 62, k, 300, 300, 0),
                                   :'STAMP'::jsonb, 18) is not null as pass
  from unnest(array[0.8,0.9,1.15,1.3]::numeric[]) k;

select 'but a wildly different size is still refused' as t,
       public.stamp_geometry_match(pg_temp.press(:'STAMP'::jsonb, 0, k, 300, 300, 0),
                                   :'STAMP'::jsonb, 18) is null as pass
  from unnest(array[0.4,2.5]::numeric[]) k;

select 'four of the five pads, rotated, still match' as t,
       public.stamp_geometry_match(
         (select jsonb_agg(e) from jsonb_array_elements(
            pg_temp.press(:'STAMP'::jsonb, 128, 1, 200, 200, 0)) with ordinality q(e,o) where o <> 2),
         :'STAMP'::jsonb, 18) is not null as pass;

select 'a shaky press still matches' as t, count(*) = 100 as pass
  from (select public.stamp_geometry_match(
          pg_temp.press(:'STAMP'::jsonb, (random()*360)::numeric, (0.85+random()*0.3)::numeric, 300, 300, 5) ,
          :'STAMP'::jsonb, 18) s from generate_series(1,100)) q
 where s is not null;


\echo
\echo '=== B. what rotation must NOT let through ==='

-- With rotation and scale free, a straight line fits any other straight line.
-- A hand resting on a phone is a straight line.
select 'four contacts in a row are refused' as t,
       public.stamp_geometry_match('[[0,0],[80,3],[160,1],[240,4]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;

select 'a gentle arc of fingers is refused' as t,
       public.stamp_geometry_match('[[0,0],[80,10],[160,14],[240,6]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;

select 'a DIFFERENT five-pad stamp is refused at every angle' as t,
       count(*) = 0 as pass
  from unnest(array[0,37,90,164,250]) d
 where public.stamp_geometry_match(
         pg_temp.press('[[0,0],[233,33],[50,183],[183,193],[127,100]]'::jsonb, d, 1, 300, 300, 0),
         :'STAMP'::jsonb, 18) is not null;

-- The number that matters. Measured rather than argued about.
select 'out of 3000 random four-finger presses, none match' as t,
       count(*) = 0 as pass
  from (select (select jsonb_agg(jsonb_build_array(round((random()*400)::numeric,1),
                                                   round((random()*400)::numeric,1)))
                  from generate_series(1,4)) pts
          from generate_series(1,3000)) r
 where public.stamp_geometry_match(r.pts, :'STAMP'::jsonb, 18) is not null;

select 'fewer than four contacts is still never attempted' as t,
       public.stamp_geometry_match(
         pg_temp.press('[[0,0],[200,0],[0,200]]'::jsonb, 30, 1, 0, 0, 0), :'STAMP'::jsonb, 18) is null as pass;


\echo
\echo '=== C. the family portal still works, now at any angle ==='
select pg_temp.act_as('70000000-0000-0000-0000-00000000000a','rot-owner@t.example');
select public.stamp_geometry_set(:'STAMP'::jsonb, 18) is not null as _setup;

select pg_temp.act_as('70000000-0000-0000-0000-0000000000c0','rot-parent@t.example');
create temp table _rc as
  select public.stamp_begin_geometry(pg_temp.press(:'STAMP'::jsonb, 214, 1.1, 150, 400, 3)) as r;

select 'a rotated press opens a session' as t, ((select r from _rc)->>'ok')::boolean as pass;
select 'recorded as a stamp' as t, (select r from _rc)->>'trigger' = 'stamp' as pass;


\echo
\echo '=== D. the student portal, which had no way in at all ==='
select pg_temp.act_as(null,null);            -- that portal has no login

select 'a wrong PIN opens nothing' as t,
       public.stamp_begin_geometry_student('ROTREA','0000', :'STAMP'::jsonb)->>'error' = 'no_match' as pass;

select 'an unknown code opens nothing' as t,
       public.stamp_begin_geometry_student('NOSUCH','4321', :'STAMP'::jsonb)->>'error' = 'no_match' as pass;

select 'the right code and PIN with the WRONG stamp opens nothing' as t,
       public.stamp_begin_geometry_student('ROTREA','4321',
         '[[0,0],[233,33],[50,183],[183,193],[127,100]]'::jsonb)->>'error' = 'no_match' as pass;

create temp table _sc as
  select public.stamp_begin_geometry_student('ROTREA','4321',
           pg_temp.press(:'STAMP'::jsonb, 88, 1, 120, 300, 2)) as r;

select 'the right code, PIN and stamp opens a session' as t,
       ((select r from _sc)->>'ok')::boolean as pass;

select 'bound to that one card, and only that one' as t,
       jsonb_array_length((select r from _sc)->'students') = 1
   and (select r from _sc)->'students'->0->>'name' = 'Rea' as pass;

select 'the session carries no parent, only the card' as t,
       parent_email is null and card_id = '72000000-0000-0000-0000-0000000000ca' as pass
  from public.stamp_confirmations order by created_at desc limit 1;

create temp table _sr as
  select public.stamp_confirm_student(((select r from _sc)->>'confirmation')::uuid,
           'ROTREA','4321', 50) as r;

select 'and it records the payment' as t, ((select r from _sr)->>'ok')::boolean as pass;

select 'written the same way every other trigger writes it' as t,
       (payments->'2026-01'->>'paid')::boolean and (payments->'2026-01'->>'amount')::numeric = 50 as pass
  from public.cards where id='72000000-0000-0000-0000-0000000000ca';

select 'stamped as a stamp, and attributed to the student portal' as t,
       history->0->>'trigger_source' = 'stamp'
   and history->0->>'confirmed_by' = 'student:ROTREA' as pass
  from public.cards where id='72000000-0000-0000-0000-0000000000ca';

select 'single-use, like every other session' as t,
       public.stamp_confirm_student(((select r from _sc)->>'confirmation')::uuid,
         'ROTREA','4321', 50)->>'error' = 'expired' as pass;

select 'and the student can undo it' as t,
       (public.stamp_undo_student('ROTREA','4321', ((select r from _sr)->>'n')::int)->>'ok')::boolean as pass;

select 'which put the card back exactly as it was' as t, payments = '{}'::jsonb as pass
  from public.cards where id='72000000-0000-0000-0000-0000000000ca';


\echo
\echo '=== E. one card''s code cannot reach another card ==='
insert into public.cards(id,business_id,name,share_code,pin,payments,history) values
  ('72000000-0000-0000-0000-0000000000cb','71000000-0000-0000-0000-000000000001','Other','ROTOTH','9876','{}','[]');

create temp table _sc2 as
  select public.stamp_begin_geometry_student('ROTREA','4321',
           pg_temp.press(:'STAMP'::jsonb, 12, 1, 100, 100, 0)) as r;

select 'a session opened for one student cannot be spent with another''s code' as t,
       public.stamp_confirm_student(((select r from _sc2)->>'confirmation')::uuid,
         'ROTOTH','9876', 50)->>'error' = 'expired' as pass;

select 'and nothing was written to either card' as t, count(*) = 0 as pass
  from public.cards
 where id in ('72000000-0000-0000-0000-0000000000ca','72000000-0000-0000-0000-0000000000cb')
   and payments <> '{}'::jsonb;

select 'a family-portal session cannot be spent through the student path' as t, pass from (
  select pg_temp.act_as('70000000-0000-0000-0000-0000000000c0','rot-parent@t.example'),
         public.stamp_confirm_student(
           (public.stamp_begin_geometry(pg_temp.press(:'STAMP'::jsonb,0,1,0,0,0))->>'confirmation')::uuid,
           'ROTREA','4321', 50)->>'error' = 'expired' as pass) _;

select pg_temp.act_as(null,null);
select 'a student-portal session cannot be spent through the family path' as t,
       public.stamp_confirm(((select r from _sc2)->>'confirmation')::uuid,
         '72000000-0000-0000-0000-0000000000ca', 50)->>'error' = 'not_authenticated' as pass;


\echo
\echo '=== F. the PIN attempt limit is shared with the portal''s own login ==='
select 'five wrong PINs lock the code out' as t, count(*) = 5 as pass
  from (select public.stamp_begin_geometry_student('ROTOTH','0000', :'STAMP'::jsonb) r
          from generate_series(1,5)) q
 where r->>'error' = 'no_match';

select 'after which even the right PIN gets nothing' as t,
       public.stamp_begin_geometry_student('ROTOTH','9876',
         pg_temp.press(:'STAMP'::jsonb, 0, 1, 0, 0, 0))->>'error' = 'no_match' as pass;


\echo
\echo '=== G. the stamp switches itself on when a school calibrates ==='
-- The per-device flag is gone as a default. What decides whether a phone
-- listens is whether the school has a stamp registered, so these are the
-- assertions that say a parent needs to do nothing at all.

select pg_temp.act_as('70000000-0000-0000-0000-00000000000a','rot-owner@t.example');
select public.stamp_geometry_clear() is not null as _setup;

select pg_temp.act_as('70000000-0000-0000-0000-0000000000c0','rot-parent@t.example');
select 'with no stamp registered, a parent''s phone does not listen' as t,
       (public.stamp_trigger_active()->>'active')::boolean = false as pass;

select pg_temp.act_as(null,null);
select 'nor does an open student card' as t,
       (public.stamp_trigger_active_student('ROTREA','4321')->>'active')::boolean = false as pass;

select pg_temp.act_as('70000000-0000-0000-0000-00000000000a','rot-owner@t.example');
select public.stamp_geometry_set(:'STAMP'::jsonb, 18) is not null as _setup;

select pg_temp.act_as('70000000-0000-0000-0000-0000000000c0','rot-parent@t.example');
select 'the moment the school calibrates, the parent''s phone listens' as t,
       (public.stamp_trigger_active()->>'active')::boolean as pass;

select pg_temp.act_as(null,null);
select 'and so does the student card' as t,
       (public.stamp_trigger_active_student('ROTREA','4321')->>'active')::boolean as pass;

select 'a logged-out visitor is told no' as t,
       (public.stamp_trigger_active()->>'active')::boolean = false as pass;

select 'a wrong PIN is told no rather than the truth' as t,
       (public.stamp_trigger_active_student('ROTREA','0000')->>'active')::boolean = false as pass;

select pg_temp.act_as('60000000-0000-0000-0000-0000000000d0','someone-else@t.example');
select 'somebody with no children anywhere is told no' as t,
       (public.stamp_trigger_active()->>'active')::boolean = false as pass;

select 'neither call ever returns the pattern itself' as t,
       not (public.stamp_trigger_active() ? 'points')
   and not (public.stamp_trigger_active_student('ROTREA','4321') ? 'points') as pass;

select 'anon may ask about a card it holds, but not the account question' as t,
       has_function_privilege('anon', p1.oid, 'execute')
   and not has_function_privilege('anon', p2.oid, 'execute') as pass
  from pg_proc p1, pg_proc p2
 where p1.proname = 'stamp_trigger_active_student' and p2.proname = 'stamp_trigger_active';
