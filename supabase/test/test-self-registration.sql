-- Behavioural test for migration-self-registration.sql, run as the real roles.
\set ON_ERROR_STOP off
\pset pager off

-- ---------------------------------------------------------------- seed
set role postgres;
insert into auth.users(id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@a.test'),
  ('22222222-2222-2222-2222-222222222222','owner@b.test')
on conflict do nothing;

insert into public.businesses(id, owner_id, biz_code, name, type, fee, year, approval_status)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'BIZ-AAA','Swim Smooth','Swimming',50,2026,'approved'),
       ('bbbbbbbb-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
        'BIZ-BBB','Rival School','Music',40,2026,'approved'),
       ('cccccccc-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111',
        'BIZ-CCC','Not Yet Approved','Dance',30,2026,'pending')
on conflict do nothing;

insert into public.groups(id, business_id, name, schedule) values
  ('9d000000-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-000000000001','Dolphins','[{"day":"Monday"}]'),
  ('9d000000-0000-0000-0000-0000000000d2','aaaaaaaa-0000-0000-0000-000000000001','Sharks','[]'),
  ('9d000000-0000-0000-0000-0000000000d9','bbbbbbbb-0000-0000-0000-000000000002','Rival Group','[]')
on conflict do nothing;

insert into public.registration_links(id, business_id, group_id, token, label, is_active) values
  ('11100000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001', null,
     'opentoken','Autumn flyer', true),
  ('11100000-0000-0000-0000-0000000000a2','aaaaaaaa-0000-0000-0000-000000000001',
     '9d000000-0000-0000-0000-0000000000d1','dolphinstoken','Dolphins only', true),
  ('11100000-0000-0000-0000-0000000000a3','aaaaaaaa-0000-0000-0000-000000000001', null,
     'deadtoken','Switched off', false),
  ('11100000-0000-0000-0000-0000000000a4','cccccccc-0000-0000-0000-000000000003', null,
     'pendingbiztoken','Unapproved biz', true)
on conflict do nothing;

\echo
\echo '=== A. get_registration_form, as anon ==='
set role anon;
select 'open link shows school + group list' as t,
       (public.get_registration_form('opentoken') -> 'business' ->> 'name') = 'Swim Smooth'
       and jsonb_array_length(public.get_registration_form('opentoken') -> 'groups') = 2
       and public.get_registration_form('opentoken') -> 'group' = 'null'::jsonb as pass;
select 'group link shows one group, no list' as t,
       (public.get_registration_form('dolphinstoken') -> 'group' ->> 'name') = 'Dolphins'
       and jsonb_array_length(public.get_registration_form('dolphinstoken') -> 'groups') = 0 as pass;
select 'form never leaks fee / code / owner' as t,
       not (public.get_registration_form('opentoken')::text ilike any(array['%BIZ-AAA%','%owner%','%"fee"%','%50%'])) as pass,
       public.get_registration_form('opentoken')::text as detail;
select 'unknown token -> null' as t, public.get_registration_form('nope') is null as pass;
select 'deactivated link -> null' as t, public.get_registration_form('deadtoken') is null as pass;
select 'unapproved business -> null' as t, public.get_registration_form('pendingbiztoken') is null as pass;

\echo
\echo '=== B. anon has no table access at all ==='
select 'anon cannot read registration_requests' as t;
select * from public.registration_requests;
select 'anon cannot read registration_links' as t;
select * from public.registration_links;
select 'anon cannot read reg_attempts' as t;
select * from public.reg_attempts;
select 'anon cannot read groups' as t;
select * from public.groups;
select 'anon cannot insert a request directly' as t;
insert into public.registration_requests(business_id, first_name, last_name)
  values ('aaaaaaaa-0000-0000-0000-000000000001','Forged','Row');

\echo
\echo '=== C. submit_registration ==='
set role anon;
select 'honeypot returns ok' as t,
       public.submit_registration('opentoken','Bot','Bot',null,null,null,null,'x') = '{"ok": true}'::jsonb as pass;
set role postgres;
select 'honeypot wrote nothing' as t, count(*) = 0 as pass
  from public.registration_requests where first_name = 'Bot';
select 'honeypot did not consume throttle' as t, count(*) = 0 as pass from public.reg_attempts;

set role anon;
select 'blank name rejected' as t,
       public.submit_registration('opentoken','   ','Person') ->> 'error' = 'name_required' as pass;
select 'unknown token rejected' as t,
       public.submit_registration('nope','A','B') ->> 'error' = 'invalid_link' as pass;
select 'deactivated link rejected' as t,
       public.submit_registration('deadtoken','A','B') ->> 'error' = 'invalid_link' as pass;
select 'unapproved business rejected' as t,
       public.submit_registration('pendingbiztoken','A','B') ->> 'error' = 'invalid_link' as pass;

select 'good submission returns ok + id' as t,
       (public.submit_registration('opentoken','  Andreas ',' Christou ','99123456','a@b.test','2015-04-02',
        '9d000000-0000-0000-0000-0000000000d2') ->> 'ok')::boolean as pass;
set role postgres;
select 'names trimmed, group honoured' as t,
       first_name = 'Andreas' and last_name = 'Christou'
       and group_id = '9d000000-0000-0000-0000-0000000000d2'
       and status = 'pending' and card_id is null
       and date_of_birth = '2015-04-02' as pass
  from public.registration_requests where email = 'a@b.test';

set role anon;
select 'another business group is ignored, not accepted' as t,
       (public.submit_registration('opentoken','Foreign','Group',null,'foreign@b.test',null,
        '9d000000-0000-0000-0000-0000000000d9') ->> 'ok')::boolean as pass;
set role postgres;
select 'foreign group landed as null' as t, group_id is null as pass
  from public.registration_requests where email = 'foreign@b.test';

set role anon;
select 'a group link ignores the submitted group' as t,
       (public.submit_registration('dolphinstoken','Locked','In',null,'locked@b.test',null,
        '9d000000-0000-0000-0000-0000000000d9') ->> 'ok')::boolean as pass;
set role postgres;
select 'group forced to the link group' as t,
       group_id = '9d000000-0000-0000-0000-0000000000d1' as pass
  from public.registration_requests where email = 'locked@b.test';
select 'empty phone/email stored as null not blank' as t, phone is null and email is null as pass
  from public.registration_requests where first_name = 'Foreign' and false
  union all
  select 'empty phone stored as null', (select phone is null from public.registration_requests where email='foreign@b.test');

\echo
\echo '=== D. throttle ==='
set role postgres;
delete from public.reg_attempts;
delete from public.registration_requests where first_name = 'Rate';
set role anon;
select 'no-header path: 6 through, then blocked' as t,
       count(*) filter (where e is null) = 6
       and count(*) filter (where e = 'rate_limited') = 2 as pass
  from (select public.submit_registration('opentoken','Rate','Limit') ->> 'error' as e
          from generate_series(1,8)) s;
set role postgres;
select 'no-header path falls back to the token bucket, not to no limit' as t,
       bucket = 'token:opentoken' as pass, bucket as detail
  from public.reg_attempts group by bucket;
set role anon;

\echo '--- with an x-forwarded-for header present (the real request path) ---'
set role postgres;
delete from public.reg_attempts;
delete from public.registration_requests where first_name in ('Rate','IpA','IpB');
set role anon;
set request.headers = '{"x-forwarded-for":"203.0.113.9, 70.41.3.18"}';
select 'ip path: 6 allowed then blocked' as t,
       count(*) filter (where e is null) = 6 and count(*) filter (where e = 'rate_limited') = 2 as pass
  from (select public.submit_registration('opentoken','IpA','One') ->> 'error' as e
          from generate_series(1,8)) s;
set role postgres;
select 'bucket is the first (client) IP, not the proxy chain' as t,
       bucket = '203.0.113.9' as pass, bucket as detail
  from public.reg_attempts group by bucket;

\echo '--- a different IP is a separate bucket ---'
set role anon;
set request.headers = '{"x-forwarded-for":"198.51.100.7"}';
select 'fresh IP is not blocked by the first ones quota' as t,
       (public.submit_registration('opentoken','IpB','Two') ->> 'ok')::boolean as pass;
reset request.headers;

\echo
\echo '=== E. owner isolation, as authenticated ==='
set role postgres;
delete from public.registration_requests where first_name in ('Rate','IpA','IpB');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select 'owner A sees their own links' as t, count(*) = 3 as pass, count(*) as detail
  from public.registration_links;
select 'owner A sees their own requests' as t, count(*) = 3 as pass, count(*) as detail
  from public.registration_requests;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select 'owner B sees none of A''s links' as t, count(*) = 0 as pass from public.registration_links;
select 'owner B sees none of A''s requests' as t, count(*) = 0 as pass from public.registration_requests;
select 'owner B cannot approve A''s request' as t,
       public.approve_registration(
         (select id from public.registration_requests r
           where exists (select 1 from public.registration_requests) limit 1),
         'ZZZZZ','9999') ->> 'error' = 'not_found' as pass;

\echo
\echo '=== F. approval ==='
-- psql variables, not a temp table: a temp table created as postgres is not
-- readable once we SET ROLE authenticated, which is the role under test.
set role postgres;
select id as req_andreas from public.registration_requests where email = 'a@b.test' \gset
select id as req_foreign from public.registration_requests where email = 'foreign@b.test' \gset
select id as req_locked  from public.registration_requests where email = 'locked@b.test' \gset

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select 'approve returns the new card' as t,
       (r ->> 'ok')::boolean
       and r -> 'card' ->> 'name' = 'Andreas Christou'
       and r -> 'card' ->> 'share_code' = 'AQ3RG'
       and r -> 'card' ->> 'pin' = '3821'
       and r -> 'card' ->> 'group_id' = '9d000000-0000-0000-0000-0000000000d2' as pass,
       r::text as detail
  from (select public.approve_registration(:'req_andreas','AQ3RG','3821') as r) x;

select 'card exists, DOB and phone carried over, JSON defaults sane' as t,
       name = 'Andreas Christou' and pin = '3821' and phone = '99123456'
       and date_of_birth = '2015-04-02'
       and payments = '{}'::jsonb and history = '[]'::jsonb
       and lesson_schedule = '[]'::jsonb and level is null as pass
  from public.cards where share_code = 'AQ3RG';

select 'request flipped to approved and linked to the card' as t,
       r.status = 'approved' and r.decided_at is not null
       and r.card_id = (select id from public.cards where share_code = 'AQ3RG') as pass
  from public.registration_requests r where r.id = :'req_andreas';

select 'second approval refused' as t,
       public.approve_registration(:'req_andreas','BBBBB','1111') ->> 'error'
       = 'already_approved' as pass;
select 'and no second card was written' as t, count(*) = 0 as pass
  from public.cards where share_code = 'BBBBB';

select 'owner may override the group at approval' as t,
       public.approve_registration(:'req_foreign','CCCCC','2222',
         '9d000000-0000-0000-0000-0000000000d1')
         -> 'card' ->> 'group_id' = '9d000000-0000-0000-0000-0000000000d1' as pass;

-- An override naming another business's group must NOT fall back to whatever
-- the applicant picked -- that would quietly file the student in a class the
-- owner did not choose. The student lands ungrouped instead, which is visible.
select 'an override pointing at another business yields an ungrouped student' as t,
       public.approve_registration(:'req_locked','DDDDD','3333',
         '9d000000-0000-0000-0000-0000000000d9')
         -> 'card' -> 'group_id' = 'null'::jsonb as pass;
set role postgres;
select 'and the student was still created' as t,
       exists (select 1 from public.cards where share_code = 'DDDDD' and group_id is null) as pass;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select 'unknown request id -> not_found' as t,
       public.approve_registration('00000000-0000-0000-0000-000000000000','EEEEE','4444')
       ->> 'error' = 'not_found' as pass;

\echo
\echo '=== G. the approved student behaves like any other ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select 'shows up in the owner''s card list' as t, count(*) = 3 as pass, count(*) as detail
  from public.cards where business_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role anon;
select 'logs in with share code + PIN like a hand-added student' as t,
       (public.get_student_card('AQ3RG','3821') -> 'card' ->> 'name') = 'Andreas Christou' as pass;
-- CCCCC is the one approved with a valid group override, so this is the
-- regression that matters: groups must still reach the student portal.
select 'and its group still resolves through the live RPC' as t,
       (public.get_student_card('CCCCC','2222') -> 'card' -> 'group' ->> 'name') = 'Dolphins' as pass,
       (public.get_student_card('CCCCC','2222') -> 'card' -> 'group')::text as detail;
select 'the owner-chosen accent still reaches the student' as t,
       public.get_student_card('AQ3RG','3821') -> 'business' ? 'accent' as pass;

\echo
\echo '=== H. cascade behaviour ==='
set role postgres;
delete from public.groups where id = '9d000000-0000-0000-0000-0000000000d1';
select 'deleting a class removes its dedicated link' as t,
       not exists (select 1 from public.registration_links where token = 'dolphinstoken') as pass;
select 'open links survive' as t,
       exists (select 1 from public.registration_links where token = 'opentoken') as pass;
select 'requests survive, group_id nulled rather than deleted' as t,
       exists (select 1 from public.registration_requests where email = 'locked@b.test' and group_id is null) as pass;
select 'approved students are untouched by the class deletion' as t,
       exists (select 1 from public.cards where share_code = 'AQ3RG') as pass;
delete from public.businesses where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select 'deleting a business takes its links and requests with it' as t,
       not exists (select 1 from public.registration_links where token = 'opentoken')
       and not exists (select 1 from public.registration_requests) as pass;
