-- Behavioural test for migration-announcement-targeting.sql.
--
-- The check that matters most is D: a note written for one student must not be
-- readable by another student at the same school, who needs only a share code
-- and a PIN to ask.
\set ON_ERROR_STOP off
\pset pager off

set role postgres;
insert into auth.users(id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@a.test'),
  ('22222222-2222-2222-2222-222222222222','owner@b.test')
on conflict do nothing;

insert into public.businesses(id, owner_id, biz_code, name, type, fee, year, approval_status)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'BIZ-AAA','Swim Smooth','Swimming',45,2026,'approved'),
       ('bbbbbbbb-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
        'BIZ-BBB','Rival School','Music',40,2026,'approved')
on conflict do nothing;

insert into public.groups(id, business_id, name, schedule) values
  ('9d000000-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-000000000001','Sharks','[]'),
  ('9d000000-0000-0000-0000-0000000000d2','aaaaaaaa-0000-0000-0000-000000000001','Dolphins','[]'),
  ('9d000000-0000-0000-0000-0000000000d9','bbbbbbbb-0000-0000-0000-000000000002','Rival Class','[]')
on conflict do nothing;

-- SHARK1 is in Sharks, DOLPH1 in Dolphins, NOGRP1 in no class at all.
insert into public.cards(id, business_id, name, share_code, pin, group_id, payments, history) values
  ('c0000000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','Shark Kid','SHARK1','1111','9d000000-0000-0000-0000-0000000000d1','{}','[]'),
  ('c0000000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001','Dolphin Kid','DOLPH1','2222','9d000000-0000-0000-0000-0000000000d2','{}','[]'),
  ('c0000000-0000-0000-0000-00000000000c','aaaaaaaa-0000-0000-0000-000000000001','No Class Kid','NOGRP1','3333',null,'{}','[]')
on conflict do nothing;

-- One parent, linked to the Sharks child only.
insert into public.card_links(card_id, parent_email) values
  ('c0000000-0000-0000-0000-00000000000a','parent@t.test')
on conflict do nothing;

insert into public.announcements(id, business_id, title, group_id, card_id) values
  ('a0000000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','Term starts Monday', null, null),
  ('a0000000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001','Sharks move to Thursday','9d000000-0000-0000-0000-0000000000d1', null),
  ('a0000000-0000-0000-0000-00000000000c','aaaaaaaa-0000-0000-0000-000000000001','Dolphins pool closed','9d000000-0000-0000-0000-0000000000d2', null),
  ('a0000000-0000-0000-0000-00000000000d','aaaaaaaa-0000-0000-0000-000000000001','About Shark Kid only', null,'c0000000-0000-0000-0000-00000000000a')
on conflict do nothing;

\echo
\echo '=== A. the student who IS the audience ==='
set role anon;
select 'the Sharks student sees school + their class + their own note' as t,
       jsonb_array_length(public.get_student_card('SHARK1','1111') -> 'announcements') = 3 as pass,
       (select string_agg(x ->> 'title', ' | ')
          from jsonb_array_elements(public.get_student_card('SHARK1','1111') -> 'announcements') x) as detail;

\echo
\echo '=== B. a student in a DIFFERENT class ==='
select 'the Dolphins student sees school + Dolphins only' as t,
       jsonb_array_length(public.get_student_card('DOLPH1','2222') -> 'announcements') = 2 as pass,
       (select string_agg(x ->> 'title', ' | ')
          from jsonb_array_elements(public.get_student_card('DOLPH1','2222') -> 'announcements') x) as detail;
select 'and never the Sharks class note' as t,
       not (public.get_student_card('DOLPH1','2222')::text like '%Sharks move%') as pass;

\echo
\echo '=== C. a student in no class at all ==='
select 'sees the school-wide note and nothing else' as t,
       jsonb_array_length(public.get_student_card('NOGRP1','3333') -> 'announcements') = 1 as pass,
       (select string_agg(x ->> 'title', ' | ')
          from jsonb_array_elements(public.get_student_card('NOGRP1','3333') -> 'announcements') x) as detail;

\echo
\echo '=== D. THE PRIVACY ONE: a note for one student ==='
-- A share code and a PIN is all it takes to call this, so a leak here is a
-- leak to anyone holding any student card at the school.
select 'the Dolphins student cannot read it' as t,
       not (public.get_student_card('DOLPH1','2222')::text like '%About Shark Kid only%') as pass;
select 'nor can the unassigned student' as t,
       not (public.get_student_card('NOGRP1','3333')::text like '%About Shark Kid only%') as pass;
select 'but the student it is about can' as t,
       public.get_student_card('SHARK1','1111')::text like '%About Shark Kid only%' as pass;

\echo
\echo '=== E. the labels the portal will show ==='
select 'a school-wide note is tagged all' as t,
       (select x ->> 'target_kind' from jsonb_array_elements(public.get_student_card('SHARK1','1111') -> 'announcements') x
         where x ->> 'title' = 'Term starts Monday') = 'all' as pass;
select 'a class note carries the class name' as t,
       (select (x ->> 'target_kind') || '/' || (x ->> 'target_name')
          from jsonb_array_elements(public.get_student_card('SHARK1','1111') -> 'announcements') x
         where x ->> 'title' = 'Sharks move to Thursday') = 'group/Sharks' as pass;
select 'a student note carries the student name' as t,
       (select (x ->> 'target_kind') || '/' || (x ->> 'target_name')
          from jsonb_array_elements(public.get_student_card('SHARK1','1111') -> 'announcements') x
         where x ->> 'title' = 'About Shark Kid only') = 'student/Shark Kid' as pass;

\echo
\echo '=== F. the parent feed ==='
set role authenticated;
set request.jwt.claim.email = 'parent@t.test';
select 'the Sharks parent gets the same three' as t,
       jsonb_array_length(public.get_my_announcements()) = 3 as pass,
       (select string_agg(x ->> 'title', ' | ')
          from jsonb_array_elements(public.get_my_announcements()) x) as detail;
select 'and not the other class''s note' as t,
       not (public.get_my_announcements()::text like '%Dolphins pool closed%') as pass;

set request.jwt.claim.email = 'nobody@t.test';
select 'an unrelated parent sees none of it' as t,
       public.get_my_announcements() = '[]'::jsonb as pass;

\echo
\echo '=== G. a target must belong to the same business ==='
set role postgres;
select 'pointing at another school''s class is refused' as t;
insert into public.announcements(business_id, title, group_id)
values ('aaaaaaaa-0000-0000-0000-000000000001','cross-school','9d000000-0000-0000-0000-0000000000d9');
select 'both targets at once is refused' as t;
insert into public.announcements(business_id, title, group_id, card_id)
values ('aaaaaaaa-0000-0000-0000-000000000001','both','9d000000-0000-0000-0000-0000000000d1','c0000000-0000-0000-0000-00000000000a');
select 'neither was written' as t, count(*) = 0 as pass
  from public.announcements where title in ('cross-school','both');

\echo
\echo '=== H. deleting the target takes the note with it ==='
-- Set null would turn a class note into a school-wide one and a private note
-- into a public one — the wrong direction to fail in.
delete from public.groups where id = '9d000000-0000-0000-0000-0000000000d2';
select 'deleting a class deletes its class note' as t,
       not exists (select 1 from public.announcements where title = 'Dolphins pool closed') as pass;
select 'and leaves the school-wide one alone' as t,
       exists (select 1 from public.announcements where title = 'Term starts Monday') as pass;
delete from public.cards where id = 'c0000000-0000-0000-0000-00000000000a';
select 'deleting a student deletes the note about them' as t,
       not exists (select 1 from public.announcements where title = 'About Shark Kid only') as pass;
