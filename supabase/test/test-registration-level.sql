-- Behavioural test for migration-registration-level.sql, run as the real roles.
\set ON_ERROR_STOP off
\pset pager off

set role postgres;
insert into auth.users(id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@a.test'),
  ('22222222-2222-2222-2222-222222222222','owner@b.test')
on conflict do nothing;

-- Level ids are generated in the browser, so two businesses can easily both
-- have an "l1". Business B's l1 is deliberately a different name and a wildly
-- different fee, so a cross-business read would be unmistakable.
insert into public.businesses(id, owner_id, biz_code, name, type, fee, year, approval_status, levels)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'BIZ-AAA','Swim Smooth','Swimming', 45, 2026,'approved',
        '[{"id":"l1","name":"Begginer","fee":50},
          {"id":"l2","name":"Medium","fee":60},
          {"id":"l3","name":"Advance","fee":70}]'),
       ('bbbbbbbb-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
        'BIZ-BBB','Rival School','Music', 40, 2026,'approved',
        '[{"id":"l1","name":"Rival Level","fee":999}]')
on conflict do nothing;

insert into public.groups(id, business_id, name, schedule) values
  ('9d000000-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-000000000001','Can swim','[]')
on conflict do nothing;

insert into public.registration_links(id, business_id, group_id, token, is_active) values
  ('11100000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001', null,'opentoken', true)
on conflict do nothing;

set role anon;
select public.submit_registration('opentoken','Lev','One',   null,'lev1@t.test') \gset x
select public.submit_registration('opentoken','Lev','Two',   null,'lev2@t.test') \gset x
select public.submit_registration('opentoken','Lev','Three', null,'lev3@t.test') \gset x
select public.submit_registration('opentoken','Lev','Four',  null,'lev4@t.test') \gset x

set role postgres;
select id as r1 from public.registration_requests where email='lev1@t.test' \gset
select id as r2 from public.registration_requests where email='lev2@t.test' \gset
select id as r3 from public.registration_requests where email='lev3@t.test' \gset
select id as r4 from public.registration_requests where email='lev4@t.test' \gset

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

\echo
\echo '=== A. a level chosen at approval reaches the student ==='
select 'the RPC returns the level it applied' as t,
       r -> 'card' -> 'level' ->> 'name' = 'Medium'
       and (r -> 'card' -> 'level' ->> 'fee')::numeric = 60 as pass,
       (r -> 'card' -> 'level')::text as detail
  from (select public.approve_registration(:'r1','LVL01','1111',null,'l2') as r) x;

set role postgres;
select 'the snapshot on the card is the school''s own level, verbatim' as t,
       level = '{"id":"l2","name":"Medium","fee":60}'::jsonb as pass,
       level::text as detail
  from public.cards where share_code = 'LVL01';

\echo
\echo '=== B. no level chosen still works, exactly as before ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select 'approving without a level succeeds' as t,
       (public.approve_registration(:'r2','LVL02','2222') ->> 'ok')::boolean as pass;
set role postgres;
select 'and leaves level null, so the business default fee applies' as t,
       level is null as pass, coalesce(level::text,'null') as detail
  from public.cards where share_code = 'LVL02';

\echo
\echo '=== C. a level id that is not the school''s is refused, not honoured ==='
-- Business B also has an "l1". Reading it here would price this student at
-- 999 instead of 50 — the whole reason the lookup is scoped to the business.
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select 'passing l1 resolves to THIS school''s l1, not the other school''s' as t,
       r -> 'card' -> 'level' ->> 'name' = 'Begginer'
       and (r -> 'card' -> 'level' ->> 'fee')::numeric = 50 as pass,
       (r -> 'card' -> 'level')::text as detail
  from (select public.approve_registration(:'r3','LVL03','3333',null,'l1') as r) x;

select 'an id that exists nowhere leaves the level null' as t,
       r -> 'card' -> 'level' = 'null'::jsonb as pass,
       (r -> 'card' -> 'level')::text as detail
  from (select public.approve_registration(:'r4','LVL04','4444',null,'not-a-level') as r) x;
set role postgres;
select 'and the student is still created rather than lost' as t,
       exists (select 1 from public.cards where share_code = 'LVL04') as pass;

\echo
\echo '=== D. the fee the app will show ==='
-- Mirrors cardFee(card, biz): the level fee when there is one, else biz.fee.
select c.share_code as t,
       coalesce((c.level ->> 'fee')::numeric, b.fee) as fee_shown,
       coalesce(c.level ->> 'name', '(default)') as level_name
  from public.cards c join public.businesses b on b.id = c.business_id
 where c.share_code like 'LVL0%'
 order by c.share_code;

\echo
\echo '=== E. exactly one function, and anon still cannot call it ==='
select 'one approve_registration, five arguments' as t,
       count(*) = 1 as pass, string_agg(p.oid::regprocedure::text, ' | ') as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'approve_registration';
select 'owners can execute it' as t,
       has_function_privilege('authenticated',
         'public.approve_registration(uuid,text,text,uuid,text)','execute') as pass;
-- has_function_privilege, not the GRANT statements: Postgres hands EXECUTE to
-- PUBLIC by default and every role inherits it, so reading the grants alone
-- would say "not granted to anon" while anon could call it perfectly well.
select 'anonymous visitors cannot' as t,
       not has_function_privilege('anon',
         'public.approve_registration(uuid,text,text,uuid,text)','execute') as pass;
select 'and PUBLIC holds nothing on it either' as t,
       not has_function_privilege('public',
         'public.approve_registration(uuid,text,text,uuid,text)','execute') as pass;
select 'the two public functions ARE still reachable by anon' as t,
       has_function_privilege('anon','public.get_registration_form(text)','execute')
       and has_function_privilege('anon',
         'public.submit_registration(text,text,text,text,text,date,uuid,text)','execute') as pass;

\echo
\echo '=== F. the other business is still walled off ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select 'owner B cannot approve owner A''s request even with a level' as t,
       public.approve_registration(:'r1','XXXXX','9999',null,'l1') ->> 'error'
       = 'not_found' as pass;
