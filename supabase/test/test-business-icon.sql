-- Behavioural test for migration-business-icon.sql (Part A) and its Part B.
--
-- The feature is only half delivered by Part A: an owner reads the businesses
-- row directly, but parents and students read through get_my_cards() and
-- get_student_card(), which build the business object key by key. This checks
-- the icon actually arrives at both, and that null still means "use my
-- category's icon" rather than a missing key.
\set ON_ERROR_STOP off
\pset pager off

set role postgres;
insert into auth.users(id, email) values
  ('33333333-3333-3333-3333-333333333333','owner@icon.test')
on conflict do nothing;

insert into public.businesses(id, owner_id, biz_code, name, type, fee, year, approval_status)
values ('cccccccc-0000-0000-0000-000000000003','33333333-3333-3333-3333-333333333333',
        'BIZ-ICO','Giorkos schools','Other',65,2026,'approved')
on conflict do nothing;

insert into public.cards(id, business_id, name, share_code, pin, payments, history) values
  ('c1000000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000003',
   'Afrodite Marina','ICON01','4321','{}','[]')
on conflict do nothing;

insert into public.card_links(card_id, parent_email) values
  ('c1000000-0000-0000-0000-000000000001','parent@icon.test')
on conflict do nothing;

\echo
\echo '=== A. before the owner chooses: null, and the key is present ==='
set role anon;
select 'the student read carries an icon key at all' as t,
       (public.get_student_card('ICON01','4321') -> 'business') ? 'icon' as pass;
select 'and it is null, meaning use the category icon' as t,
       jsonb_typeof(public.get_student_card('ICON01','4321') -> 'business' -> 'icon') = 'null' as pass;

set role authenticated;
set request.jwt.claim.email = 'parent@icon.test';
select 'the parent read carries it too' as t,
       (public.get_my_cards() -> 0 -> 'business') ? 'icon' as pass;

\echo
\echo '=== B. after choosing one ==='
set role postgres;
update public.businesses set icon = 'BALLET_ICON'
 where id = 'cccccccc-0000-0000-0000-000000000003';

set role anon;
select 'the student sees the chosen icon' as t,
       (public.get_student_card('ICON01','4321') -> 'business' ->> 'icon') = 'BALLET_ICON' as pass;

set role authenticated;
set request.jwt.claim.email = 'parent@icon.test';
select 'the parent sees the same one' as t,
       (public.get_my_cards() -> 0 -> 'business' ->> 'icon') = 'BALLET_ICON' as pass;

\echo
\echo '=== C. nothing else in the business object moved ==='
-- A key added by hand is easy; a key LOST by hand is the failure that matters,
-- because these functions are recreated in full every time one is touched.
set role anon;
select 'every business key the app reads is still there' as t,
       (select bool_and((public.get_student_card('ICON01','4321') -> 'business') ? k)
          from unnest(array['name','type','fee','year','biz_code','inactive_months',
                            'levels','custom_card_image','accent','icon']) k) as pass;
set role authenticated;
set request.jwt.claim.email = 'parent@icon.test';
select 'and on the parent path as well' as t,
       (select bool_and((public.get_my_cards() -> 0 -> 'business') ? k)
          from unnest(array['name','type','fee','year','biz_code','inactive_months',
                            'levels','custom_card_image','accent','icon']) k) as pass;
select 'the card object is untouched too' as t,
       (select bool_and((public.get_my_cards() -> 0 -> 'card') ? k)
          from unnest(array['id','name','level','share_code','payments','history',
                            'enrollment_start_month','paused_months','fee_history',
                            'group_name','lesson_schedule','group_id','group','child_id']) k) as pass;

\echo
\echo '=== D. clearing it goes back to the category icon ==='
set role postgres;
update public.businesses set icon = null
 where id = 'cccccccc-0000-0000-0000-000000000003';
set role anon;
select 'null again, not an empty string' as t,
       jsonb_typeof(public.get_student_card('ICON01','4321') -> 'business' -> 'icon') = 'null' as pass;
