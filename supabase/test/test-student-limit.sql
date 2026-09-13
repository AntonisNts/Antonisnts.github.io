-- Student limit per plan (migration-student-limit.sql).
-- Verdicts are the `pass` column: t or f. Run via ./run-tests.sh.

\echo '=== fixtures ==='
insert into auth.users(id,email) values
  ('a0000000-0000-0000-0000-00000000000a','owner-a@t.example'),
  ('b0000000-0000-0000-0000-00000000000b','owner-b@t.example');

-- A school on Starter, and one left on unlimited.
insert into public.businesses(id,owner_id,biz_code,name,type,fee,year,approval_status,plan) values
  ('a1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-00000000000a','LIM-A','Starter School','Music',45,2026,'approved','starter'),
  ('b1000000-0000-0000-0000-000000000002','b0000000-0000-0000-0000-00000000000b','LIM-B','Unlimited School','Music',45,2026,'approved','unlimited');

\echo
\echo '=== A. the column ==='
select 'new businesses default to starter' as t,
       (select column_default like '%starter%' from information_schema.columns
         where table_name='businesses' and column_name='plan') as pass;

select 'only the four real plans are accepted' as t,
       count(*) = 1 as pass
  from pg_constraint where conname = 'businesses_plan_check';

\echo
\echo '=== B. one at a time ==='
insert into public.cards(business_id,name,share_code,pin)
select 'a1000000-0000-0000-0000-000000000001','S'||i,'SC'||i,'1234' from generate_series(1,25) i;

select 'a Starter school reaches 25' as t, count(*) = 25 as pass
  from public.cards where business_id='a1000000-0000-0000-0000-000000000001';

do $$
begin
  insert into public.cards(business_id,name,share_code,pin)
  values ('a1000000-0000-0000-0000-000000000001','Over','SCover','1234');
  create temp table _r26 as select false as pass, 'no error raised'::text as detail;
exception when others then
  create temp table _r26 as select sqlerrm like '%Starter plan covers 25%' as pass, sqlerrm::text as detail;
end $$;
select 'the 26th is refused, with a message naming the plan and the number' as t, pass, detail from _r26;
drop table _r26;

select 'and nothing was written' as t, count(*) = 25 as pass
  from public.cards where business_id='a1000000-0000-0000-0000-000000000001';

\echo
\echo '=== C. bulk import -- the case a row-level trigger would miss ==='
-- Setup runs OUTSIDE the block: a DO block is one transaction, so putting
-- these inside would roll them back along with the expected failure and the
-- "nothing landed" check below would pass vacuously.
insert into public.cards(business_id,name,share_code,pin)
select 'b1000000-0000-0000-0000-000000000002','X'||i,'XC'||i,'1234' from generate_series(1,100) i;
update public.businesses set plan='starter' where biz_code='LIM-B';

do $$
begin
  insert into public.cards(business_id,name,share_code,pin)
  select 'b1000000-0000-0000-0000-000000000002','Y'||i,'YC'||i,'1234' from generate_series(1,10) i;
  create temp table _rb as select false as pass, 'no error raised'::text as detail;
exception when others then
  create temp table _rb as select sqlerrm like '%Starter plan covers 25%' as pass, sqlerrm::text as detail;
end $$;
select 'a bulk insert that would breach the cap is refused whole' as t, pass, detail from _rb;
drop table _rb;

select 'and not one row of that batch landed' as t, count(*) = 100 as pass, count(*) as detail
  from public.cards where business_id='b1000000-0000-0000-0000-000000000002';

\echo
\echo '=== D. unlimited really is unlimited ==='
update public.businesses set plan='unlimited' where biz_code='LIM-B';
insert into public.cards(business_id,name,share_code,pin)
select 'b1000000-0000-0000-0000-000000000002','Z'||i,'ZC'||i,'1234' from generate_series(1,50) i;
select 'an unlimited school passes 150 without complaint' as t, count(*) = 150 as pass
  from public.cards where business_id='b1000000-0000-0000-0000-000000000002';

\echo
\echo '=== E. an owner cannot buy themselves an upgrade ==='
set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';
do $$
begin
  update public.businesses set plan='unlimited' where biz_code='LIM-A';
  create temp table _rp as select false as pass, 'the update was allowed'::text as detail;
exception when others then
  create temp table _rp as select true as pass, sqlerrm::text as detail;
end $$;
set role postgres;
select 'the owner is refused when writing plan' as t, pass, detail from _rp;
drop table _rp;
select 'and their plan is untouched' as t, plan = 'starter' as pass, plan as detail
  from public.businesses where biz_code='LIM-A';

\echo
\echo '=== F. the columns that ARE theirs still work ==='
set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';
update public.businesses set name='Renamed', accent='violet' where biz_code='LIM-A';
set role postgres;
select 'renaming and re-colouring still succeed' as t,
       name = 'Renamed' and accent = 'violet' as pass
  from public.businesses where biz_code='LIM-A';

\echo
\echo '=== G. approving a registration is capped too ==='
insert into public.registration_links(id,business_id,token,label,is_active)
values ('c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','limtok','Intake',true);
insert into public.registration_requests(id,link_id,business_id,first_name,last_name,status)
values ('d1000000-0000-0000-0000-000000000004','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','Maria','Test','pending');

set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';
do $$
begin
  perform public.approve_registration('d1000000-0000-0000-0000-000000000004','APPR01','9999',null,null);
  create temp table _rg as select false as pass, 'the approval went through'::text as detail;
exception when others then
  create temp table _rg as select sqlerrm like '%Starter plan covers 25%' as pass, sqlerrm::text as detail;
end $$;
set role postgres;
select 'approving at the cap is refused' as t, pass, detail from _rg;
drop table _rg;

select 'the request stays pending rather than being consumed' as t,
       status = 'pending' as pass, status as detail
  from public.registration_requests where id='d1000000-0000-0000-0000-000000000004';

\echo
\echo '=== H. moving the school up lets it through ==='
update public.businesses set plan='growth' where biz_code='LIM-A';
set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';
select 'the same approval now succeeds on Growth' as t,
       (public.approve_registration('d1000000-0000-0000-0000-000000000004','APPR01','9999',null,null) ->> 'ok')::boolean as pass;
set role postgres;
select 'the student was created' as t, count(*) = 26 as pass, count(*) as detail
  from public.cards where business_id='a1000000-0000-0000-0000-000000000001';
