-- Stamp trigger (migration-stamp-geometry.sql).
-- Verdicts are the `pass` column: t or f. Run via ./run-tests.sh.
--
-- The matching runs in the database rather than the browser, so these are the
-- tests that say the physical stamp is doing any work at all. If matching had
-- been left to the page, every one of the isolation tests below would be
-- unenforceable.

\set ON_ERROR_STOP off

\echo '=== fixtures ==='
insert into auth.users(id,email) values
  ('60000000-0000-0000-0000-00000000000a','geo-owner-a@t.example'),
  ('60000000-0000-0000-0000-00000000000b','geo-owner-b@t.example'),
  ('60000000-0000-0000-0000-0000000000c0','geo-parent@t.example'),
  ('60000000-0000-0000-0000-0000000000d0','geo-stranger@t.example');

insert into public.businesses(id,owner_id,biz_code,name,type,fee,year,approval_status) values
  ('61000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-00000000000a','GEO-A','Geo School A','Dance',50,2026,'approved'),
  ('61000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-00000000000b','GEO-B','Geo School B','Music',40,2026,'approved');

insert into public.cards(id,business_id,name,share_code,pin,payments,history) values
  ('62000000-0000-0000-0000-0000000000ca','61000000-0000-0000-0000-000000000001','Gia','GEOGIA','1111','{}','[]'),
  ('62000000-0000-0000-0000-0000000000cb','61000000-0000-0000-0000-000000000002','Bob','GEOBOB','2222','{}','[]');

-- The parent is a customer of school A only.
insert into public.card_links(card_id,parent_email) values
  ('62000000-0000-0000-0000-0000000000ca','geo-parent@t.example');

create or replace function pg_temp.act_as(p_uid text, p_email text) returns void
language sql as $$
  select set_config('request.jwt.claim.sub',   coalesce(p_uid,''),   false),
         set_config('request.jwt.claim.email', coalesce(p_email,''), false);
  select null::void;
$$;

-- A five-pad stamp: four corners of a 60px square plus an off-centre pad. The
-- asymmetry is the point -- a symmetric pattern matches itself under rotation
-- and would make these tests agree for the wrong reason.
\set STAMP '[[0,0],[60,0],[0,60],[60,60],[20,35]]'


\echo
\echo '=== A. the matcher itself ==='

select 'an exact press matches with a score of zero' as t,
       public.stamp_geometry_match(:'STAMP'::jsonb, :'STAMP'::jsonb, 18) = 0 as pass;

select 'the same stamp pressed elsewhere on the screen still matches' as t,
       public.stamp_geometry_match(
         '[[0,0],[60,0],[0,60],[60,60],[20,35]]'::jsonb,
         '[[500,300],[560,300],[500,360],[560,360],[520,335]]'::jsonb, 18) = 0 as pass;

select 'contact order does not matter' as t,
       public.stamp_geometry_match(
         '[[0,0],[20,35],[60,60],[0,60],[60,0]]'::jsonb, :'STAMP'::jsonb, 18) = 0 as pass;

select 'a sloppy press inside tolerance matches, and scores how sloppy' as t,
       public.stamp_geometry_match(
         '[[0,0],[68,5],[6,66],[64,54],[27,31]]'::jsonb, :'STAMP'::jsonb, 18) between 0.01 and 18 as pass;

select 'a press outside tolerance does not match' as t,
       public.stamp_geometry_match(
         '[[0,0],[95,0],[0,60],[60,60],[20,35]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;

select 'a different stamp entirely does not match' as t,
       public.stamp_geometry_match(
         '[[0,0],[10,0],[20,0],[30,0],[40,0]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;

-- iOS hands back at most five touches however many pads are pressed, so the
-- captured set is a subset and its leftmost point is not the stored leftmost.
select 'four of the five pads still match, anchored anywhere in the stamp' as t,
       public.stamp_geometry_match(
         '[[0,0],[60,0],[60,60],[20,35]]'::jsonb, :'STAMP'::jsonb, 18) = 0 as pass;

select 'a subset that does not start at the stored leftmost point still matches' as t,
       public.stamp_geometry_match(
         '[[0,0],[40,25],[0,60],[40,60]]'::jsonb,
         '[[0,0],[20,0],[60,0],[20,60],[60,60],[60,25]]'::jsonb, 18) is not null as pass;

select 'fewer than four points is never attempted' as t,
       public.stamp_geometry_match('[[0,0],[60,0],[60,60]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;

select 'more captured points than the stamp has is not a match' as t,
       public.stamp_geometry_match(
         '[[0,0],[60,0],[0,60],[60,60],[20,35],[99,99]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;

select 'one finger cannot stand in for two pads' as t,
       public.stamp_geometry_match(
         '[[0,0],[0,0],[0,0],[0,0]]'::jsonb, :'STAMP'::jsonb, 18) is null as pass;


\echo
\echo '=== B. calibration ==='
select pg_temp.act_as('60000000-0000-0000-0000-00000000000a','geo-owner-a@t.example');

select 'a school starts uncalibrated' as t,
       (public.stamp_geometry_get()->>'calibrated')::boolean = false as pass;

select 'three pads is refused -- the trigger could never match it' as t,
       public.stamp_geometry_set('[[0,0],[60,0],[0,60]]'::jsonb)->>'error' = 'bad_count' as pass;

select 'nine pads is refused as a runaway capture' as t,
       public.stamp_geometry_set('[[0,0],[1,1],[2,2],[3,3],[4,4],[5,5],[6,6],[7,7],[8,8]]'::jsonb)->>'error' = 'bad_count' as pass;

select 'a malformed point is refused' as t,
       public.stamp_geometry_set('[[0,0],[60,0],[0,60],[60]]'::jsonb)->>'error' = 'bad_points' as pass;

select 'an absurd tolerance is refused' as t,
       public.stamp_geometry_set(:'STAMP'::jsonb, 500)->>'error' = 'bad_tolerance' as pass;

select 'nothing was stored by any of those' as t, count(*) = 0 as pass
  from public.stamp_geometries;

select 'a good calibration is accepted' as t,
       (public.stamp_geometry_set(:'STAMP'::jsonb, 18, 3)->>'ok')::boolean as pass;

select 'and reads back with its points, so a bad capture can be seen' as t,
       (public.stamp_geometry_get()->>'calibrated')::boolean
   and (public.stamp_geometry_get()->>'point_count')::int = 5
   and public.stamp_geometry_get()->'points' = :'STAMP'::jsonb as pass;

select 're-calibrating replaces rather than adding a second row' as t,
       (public.stamp_geometry_set('[[0,0],[80,0],[0,80],[80,80]]'::jsonb, 20)->>'ok')::boolean
   and (select count(*) = 1 from public.stamp_geometries
         where business_id='61000000-0000-0000-0000-000000000001') as pass;

select 'the replacement is what is stored now' as t,
       (public.stamp_geometry_get()->>'point_count')::int = 4 as pass;

-- Put the five-pad stamp back for the rest of the suite.
select public.stamp_geometry_set(:'STAMP'::jsonb, 18, 3) is not null as _setup;

select pg_temp.act_as('60000000-0000-0000-0000-0000000000d0','geo-stranger@t.example');
select 'somebody with no business cannot calibrate' as t,
       public.stamp_geometry_set(:'STAMP'::jsonb)->>'error' = 'no_business' as pass;


\echo
\echo '=== C. the trigger ==='
select pg_temp.act_as('60000000-0000-0000-0000-0000000000c0','geo-parent@t.example');

create temp table _g1 as select public.stamp_begin_geometry(:'STAMP'::jsonb) as r;
select 'a real parent pressing the right stamp gets a session' as t,
       ((select r from _g1)->>'ok')::boolean as pass;

select 'and it is recorded as a stamp, not a tap or a scan' as t,
       (select r from _g1)->>'trigger' = 'stamp' as pass;

select 'it names their child and prefills the month, like every other way in' as t,
       s->>'name' = 'Gia' and s->>'month' = 'January' and (s->>'amount')::numeric = 50 as pass
  from (select jsonb_array_elements((select r from _g1)->'students') as s) _;

select 'the session is the same 60 seconds' as t,
       expires_at - created_at = interval '60 seconds' as pass
  from public.stamp_confirmations order by created_at desc limit 1;

select 'a press nobody registered does nothing' as t,
       public.stamp_begin_geometry('[[0,0],[10,0],[20,0],[30,0]]'::jsonb)->>'error' = 'no_match' as pass;

select 'four fingers in a rough square do not open a confirmation' as t,
       public.stamp_begin_geometry('[[0,0],[150,10],[8,140],[160,150]]'::jsonb)->>'error' = 'no_match' as pass;

select 'three points are refused before any matching is attempted' as t,
       public.stamp_begin_geometry('[[0,0],[60,0],[0,60]]'::jsonb)->>'error' = 'no_match' as pass;

select 'a logged-out press is refused' as t, pass from (
  select pg_temp.act_as(null,null),
         public.stamp_begin_geometry(:'STAMP'::jsonb)->>'error' = 'not_authenticated' as pass) _;


\echo
\echo '=== D. isolation -- the part that only works because matching is server-side ==='

-- School B registers the SAME stamp. The parent is not its customer.
select pg_temp.act_as('60000000-0000-0000-0000-00000000000b','geo-owner-b@t.example');
select public.stamp_geometry_set(:'STAMP'::jsonb, 18) is not null as _setup;

select pg_temp.act_as('60000000-0000-0000-0000-0000000000c0','geo-parent@t.example');
create temp table _g2 as select public.stamp_begin_geometry(:'STAMP'::jsonb) as r;

select 'a school the parent has no child at is never considered' as t,
       ((select r from _g2)->>'ok')::boolean as pass;

select 'so an identical stamp at another school does not create a tie' as t,
       (select business_id from public.stamp_confirmations order by created_at desc limit 1)
         = '61000000-0000-0000-0000-000000000001' as pass;

select pg_temp.act_as('60000000-0000-0000-0000-0000000000d0','geo-stranger@t.example');
select 'somebody with no children anywhere matches nothing at all' as t,
       public.stamp_begin_geometry(:'STAMP'::jsonb)->>'error' = 'no_match' as pass;

select 'and nothing was opened for them' as t, count(*) = 0 as pass
  from public.stamp_confirmations where parent_email = 'geo-stranger@t.example';

-- Two schools the parent DOES belong to, with indistinguishable stamps.
insert into public.card_links(card_id,parent_email) values
  ('62000000-0000-0000-0000-0000000000cb','geo-parent@t.example');
select pg_temp.act_as('60000000-0000-0000-0000-0000000000c0','geo-parent@t.example');
select 'two of the parent''s own schools with the same stamp is a tie, and a tie confirms nothing' as t,
       public.stamp_begin_geometry(:'STAMP'::jsonb)->>'error' = 'no_match' as pass;

delete from public.card_links
 where card_id='62000000-0000-0000-0000-0000000000cb' and parent_email='geo-parent@t.example';

select pg_temp.act_as('60000000-0000-0000-0000-00000000000a','geo-owner-a@t.example');
select 'the owner pressing their own stamp is told so, and records nothing' as t,
       (public.stamp_begin_geometry(:'STAMP'::jsonb)->>'owner')::boolean as pass;


\echo
\echo '=== E. it lands in the same confirmation flow, not a parallel one ==='
select pg_temp.act_as('60000000-0000-0000-0000-0000000000c0','geo-parent@t.example');

create temp table _g3 as select public.stamp_begin_geometry(:'STAMP'::jsonb) as r;
create temp table _r3 as
  select public.stamp_confirm(((select r from _g3)->>'confirmation')::uuid,
                              '62000000-0000-0000-0000-0000000000ca', 50) as r;

select 'stamp_confirm takes the session unchanged' as t,
       ((select r from _r3)->>'ok')::boolean as pass;

select 'the payment is written the same way every other trigger writes it' as t,
       (payments->'2026-01'->>'paid')::boolean
   and (payments->'2026-01'->>'amount')::numeric = 50 as pass
  from public.cards where id='62000000-0000-0000-0000-0000000000ca';

select 'and the history entry says it came from a stamp' as t,
       history->0->>'trigger_source' = 'stamp'
   and history->0->>'confirmed_by' = 'geo-parent@t.example' as pass
  from public.cards where id='62000000-0000-0000-0000-0000000000ca';

select 'a stamp session is single-use like any other' as t,
       public.stamp_confirm(((select r from _g3)->>'confirmation')::uuid,
                            '62000000-0000-0000-0000-0000000000ca', 50)->>'error' = 'expired' as pass;

select 'undo works on it too' as t,
       (public.stamp_undo('62000000-0000-0000-0000-0000000000ca',
                          ((select r from _r3)->>'n')::int)->>'ok')::boolean as pass;


\echo
\echo '=== F. grants ==='

select 'anon cannot call anything to do with geometry' as t, count(*) = 0 as pass
  from pg_proc p
 where (p.proname like 'stamp_geometry%' or p.proname = 'stamp_begin_geometry'
        or p.proname = 'stamp_open_session')
   and has_function_privilege('anon', p.oid, 'execute');

-- stamp_open_session takes a business id and opens a session against it with
-- no checks of its own. Granting it would hand any logged-in parent a
-- confirmation for any school they can name.
select 'stamp_open_session is reachable by nobody but the functions above' as t,
       count(*) = 0 as pass
  from pg_proc p
 where p.proname in ('stamp_open_session','stamp_geometry_match')
   and (has_function_privilege('anon', p.oid, 'execute')
     or has_function_privilege('authenticated', p.oid, 'execute'));

select 'the three calibration calls and the trigger are reachable when logged in' as t,
       count(*) = 4 as pass
  from pg_proc p
 where (p.proname like 'stamp_geometry_%' or p.proname = 'stamp_begin_geometry')
   and p.proname <> 'stamp_geometry_match'
   and has_function_privilege('authenticated', p.oid, 'execute');

select 'the geometry table is function-internal' as t, count(*) = 0 as pass
  from information_schema.role_table_grants
 where table_name = 'stamp_geometries' and grantee in ('anon','authenticated');
