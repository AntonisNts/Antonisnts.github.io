-- Payment link and pending claims (migration-payment-link.sql).
-- Verdicts are the `pass` column: t or f. Run via ./run-tests.sh.
--
-- Section B is the reason this file exists. A pending claim must not move a
-- balance, a total, or an overdue figure by a single cent. That is a property
-- of the whole system rather than of any one function, so it is asserted by
-- photographing the card and the school's owed total before and after and
-- comparing them, rather than by reading the code and believing it.

\set ON_ERROR_STOP off

\echo '=== fixtures ==='
-- One owner per school throughout. Several functions here find the caller's
-- business with `where owner_id = auth.uid() limit 1`, so an owner with two
-- schools makes half these assertions depend on which row came back first.
insert into auth.users(id,email) values
  ('a0000000-0000-0000-0000-00000000000a','pay-owner@t.example'),
  ('a0000000-0000-0000-0000-00000000000b','pay-other@t.example'),
  ('a0000000-0000-0000-0000-00000000000e','pay-nolink@t.example'),
  ('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example'),
  ('a0000000-0000-0000-0000-0000000000d0','pay-stranger@t.example');

insert into public.businesses(id,owner_id,biz_code,name,type,fee,year,approval_status) values
  ('a1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-00000000000a','PAY-A','Pay School','Dance',50,2026,'approved'),
  ('a1000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-00000000000b','PAY-B','Other School','Music',40,2026,'approved'),
  ('a1000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-00000000000e','PAY-C','No Link School','Music',40,2026,'approved');

insert into public.cards(id,business_id,name,share_code,pin,payments,history) values
  ('a2000000-0000-0000-0000-0000000000ca','a1000000-0000-0000-0000-000000000001','Nia','PAYNIA','1234','{}','[]'),
  ('a2000000-0000-0000-0000-0000000000cb','a1000000-0000-0000-0000-000000000001','Kyri','PAYKYR','5678','{}','[]'),
  ('a2000000-0000-0000-0000-0000000000cc','a1000000-0000-0000-0000-000000000002','Foreign','PAYFOR','9999','{}','[]'),
  ('a2000000-0000-0000-0000-0000000000cd','a1000000-0000-0000-0000-000000000003','Nolink','PAYNOL','8888','{}','[]');

insert into public.card_links(card_id,parent_email) values
  ('a2000000-0000-0000-0000-0000000000ca','pay-parent@t.example');

create or replace function pg_temp.act_as(p_uid text, p_email text) returns void
language sql as $$
  select set_config('request.jwt.claim.sub',   coalesce(p_uid,''),   false),
         set_config('request.jwt.claim.email', coalesce(p_email,''), false);
  select null::void;
$$;

-- What the school is owed across every student, the way the dashboard totals
-- it: everything billable and unpaid.
create or replace function pg_temp.owed() returns numeric language sql as $$
  select coalesce(sum(
    (select count(*) from generate_series(0,11) mi
      where not (b.inactive_months @> to_jsonb(mi))
        and not (c.paused_months @> to_jsonb(mi))
        and not coalesce((c.payments -> (b.year::text||'-'||lpad((mi+1)::text,2,'0')) ->> 'paid')::boolean, false)
    ) * b.fee), 0)
  from public.cards c join public.businesses b on b.id = c.business_id
 where b.biz_code = 'PAY-A';
$$;


\echo
\echo '=== A. the link itself ==='
select pg_temp.act_as('a0000000-0000-0000-0000-00000000000a','pay-owner@t.example');

select 'a school starts with no payment link' as t,
       payment_link is null as pass from public.businesses where biz_code='PAY-A';

with up as (
  update public.businesses set payment_link = 'https://revolut.me/antonis',
         payment_link_name = 'Revolut — Antonis'
   where biz_code = 'PAY-A' returning 1)
select 'an https link is accepted' as t, count(*) = 1 as pass from up;

-- The rule is a CHECK, not validation inside a function, so it holds on every
-- path into the column -- including a hand-written UPDATE in the SQL editor,
-- which is exactly what these are.
create or replace function pg_temp.try(u text) returns boolean language plpgsql as $$
begin
  update public.businesses set payment_link = u where biz_code='PAY-A';
  return true;                        -- accepted
exception when check_violation then return false;
end $$;

select 'plain http is refused'        as t, pg_temp.try('http://revolut.me/x')    = false as pass;
select 'a javascript: URL is refused' as t, pg_temp.try('javascript:alert(1)')    = false as pass;
select 'a data: URL is refused'       as t, pg_temp.try('data:text/html,<b>')     = false as pass;
select 'a bare domain is refused'     as t, pg_temp.try('revolut.me/x')           = false as pass;
select 'an attribute-escape attempt is refused' as t,
       pg_temp.try('https://revolut.me/a" onclick="x') = false as pass;
select 'and the good link survived every one of those' as t,
       payment_link = 'https://revolut.me/antonis' as pass
  from public.businesses where biz_code='PAY-A';

-- RLS is what stops one school editing another's row, and the connection
-- running these tests is the table OWNER with rolbypassrls -- so RLS is inert
-- for it and an UPDATE here would succeed no matter what the policy said.
-- Dropping to `authenticated` is the only way this assertion means anything.
select pg_temp.act_as('a0000000-0000-0000-0000-00000000000b','pay-other@t.example');
set role authenticated;
with up as (
  update public.businesses set payment_link = 'https://evil.example/x'
   where biz_code = 'PAY-A' returning 1)
select 'another school owner cannot touch this one''s link, because RLS says so' as t,
       count(*) = 0 as pass from up;

with up as (
  update public.businesses set payment_link_name = 'Mine'
   where biz_code = 'PAY-B' returning 1)
select 'while their own row is theirs to edit' as t, count(*) = 1 as pass from up;

-- Same connection, same role: the plan column is not in the grant, so this is
-- refused by privileges rather than by policy.
do $$ begin
  update public.businesses set plan = 'unlimited' where biz_code = 'PAY-B';
  create temp table _plan as select false as pass;
exception when insufficient_privilege then
  create temp table _plan as select true as pass;
end $$;
select 'and the plan column is still out of reach' as t, pass from _plan;
drop table _plan;
reset role;

select 'the good link survived the other school''s attempt' as t,
       payment_link = 'https://revolut.me/antonis' as pass
  from public.businesses where biz_code='PAY-A';



\echo
\echo '=== B. A CLAIM IS NOT A PAYMENT ==='
-- The invariant the whole feature turns on.

select pg_temp.act_as('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example');

create temp table _before as
  select (select payments from public.cards where share_code='PAYNIA') as pmts,
         (select history  from public.cards where share_code='PAYNIA') as hist,
         pg_temp.owed() as owed;

create temp table _cl as
  select public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca',
           150, current_date, 'REV-8891') as r;

select 'the claim is raised' as t, ((select r from _cl)->>'ok')::boolean as pass;

select 'the card''s payments are untouched, byte for byte' as t,
       payments = (select pmts from _before) as pass
  from public.cards where share_code='PAYNIA';

select 'no history entry was written' as t,
       history = (select hist from _before) as pass
  from public.cards where share_code='PAYNIA';

select 'the school is owed exactly what it was owed before' as t,
       pg_temp.owed() = (select owed from _before) as pass;

select 'January is still unpaid' as t,
       coalesce((payments->'2026-01'->>'paid')::boolean, false) = false as pass
  from public.cards where share_code='PAYNIA';

select 'and the parent is shown it as awaiting a decision' as t,
       jsonb_array_length(public.payment_claims_mine()) = 1
   and public.payment_claims_mine()->0->>'status' = 'pending' as pass;


\echo
\echo '=== C. what a claim may and may not say ==='

select 'a second claim on the same card is refused while one is pending' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca',
         150, current_date, null)->>'error' = 'already_pending' as pass;

select 'and there is still only one in the queue' as t, count(*) = 1 as pass
  from public.payment_claims where card_id='a2000000-0000-0000-0000-0000000000ca';

-- Against Nia, whom this parent IS linked to. Using an unlinked card would
-- have them refused as no_match before the amount was ever looked at, which
-- would pass for entirely the wrong reason.
select 'a zero amount is refused' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 0, current_date, null)->>'error' = 'bad_amount' as pass;
select 'a negative amount is refused' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', -50, current_date, null)->>'error' = 'bad_amount' as pass;
select 'an absurd amount is refused' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 999999, current_date, null)->>'error' = 'bad_amount' as pass;
select 'a date in the future is refused' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 50, current_date + 1, null)->>'error' = 'bad_date' as pass;
select 'a date two years ago is refused' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 50, current_date - 800, null)->>'error' = 'bad_date' as pass;

select 'a parent cannot claim against a child that is not theirs' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000cb', 50, current_date, null)->>'error' = 'no_match' as pass;

select 'nor against another school''s student' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000cc', 50, current_date, null)->>'error' = 'no_match' as pass;

select pg_temp.act_as('a0000000-0000-0000-0000-0000000000d0','pay-stranger@t.example');
select 'somebody with no children claims nothing' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 50, current_date, null)->>'error' = 'no_match' as pass;
select 'and sees no claims' as t, public.payment_claims_mine() = '[]'::jsonb as pass;

select pg_temp.act_as(null,null);
select 'a logged-out caller claims nothing' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 50, current_date, null)->>'error' = 'not_authenticated' as pass;

-- A school with no link published is not expecting online payments. PAY-C has
-- deliberately never had one set.
select pg_temp.act_as('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example');
insert into public.card_links(card_id,parent_email)
  values ('a2000000-0000-0000-0000-0000000000cd','pay-parent@t.example') on conflict do nothing;
select 'a school with no link set accepts no claims' as t,
       public.payment_claim_create('a2000000-0000-0000-0000-0000000000cd', 50, current_date, null)->>'error' = 'no_link' as pass;
delete from public.card_links where card_id='a2000000-0000-0000-0000-0000000000cd';


\echo
\echo '=== D. the school''s queue ==='
select pg_temp.act_as('a0000000-0000-0000-0000-00000000000a','pay-owner@t.example');

create temp table _q as select public.payment_claims_queue() as r;
select 'the claim is in the queue' as t,
       jsonb_array_length((select r from _q)->'pending') = 1 as pass;

select 'with the student, the amount and the reference the parent gave' as t,
       (select r from _q)->'pending'->0->>'name' = 'Nia'
   and ((select r from _q)->'pending'->0->>'amount')::numeric = 150
   and (select r from _q)->'pending'->0->>'reference' = 'REV-8891' as pass;

select 'a fresh claim is not stale' as t,
       ((select r from _q)->'pending'->0->>'stale')::boolean = false as pass;

update public.payment_claims set created_at = now() - interval '20 days'
 where card_id='a2000000-0000-0000-0000-0000000000ca';
select 'one left for twenty days is flagged stale, so the queue cannot grow silently' as t,
       (public.payment_claims_queue()->'pending'->0->>'stale')::boolean as pass;

select pg_temp.act_as('a0000000-0000-0000-0000-00000000000b','pay-other@t.example');
select 'another school sees none of it' as t,
       jsonb_array_length(public.payment_claims_queue()->'pending') = 0 as pass;

select 'and cannot confirm it' as t,
       public.payment_claim_confirm((select id from public.payment_claims
         where card_id='a2000000-0000-0000-0000-0000000000ca'))->>'error' = 'no_match' as pass;

select 'nor reject it' as t,
       public.payment_claim_reject((select id from public.payment_claims
         where card_id='a2000000-0000-0000-0000-0000000000ca'))->>'error' = 'no_match' as pass;

select 'and after all that the card is still untouched' as t,
       payments = (select pmts from _before) as pass
  from public.cards where share_code='PAYNIA';


\echo
\echo '=== E. confirming is what moves the money ==='
select pg_temp.act_as('a0000000-0000-0000-0000-00000000000a','pay-owner@t.example');

create temp table _cf as
  select public.payment_claim_confirm((select id from public.payment_claims
                                        where card_id='a2000000-0000-0000-0000-0000000000ca')) as r;

select 'confirming succeeds' as t, ((select r from _cf)->>'ok')::boolean as pass;

-- EUR150 at EUR50/month is three whole months, spread by the same breakdown
-- the tag and the stamp use. If this differed, two payment routes would be
-- putting money in different places.
select 'EUR150 at EUR50 a month covers three months' as t,
       ((select r from _cf)->'months') = '[0,1,2]'::jsonb as pass;

select 'and the card now says so' as t,
       (payments->'2026-01'->>'paid')::boolean
   and (payments->'2026-02'->>'paid')::boolean
   and (payments->'2026-03'->>'paid')::boolean as pass
  from public.cards where share_code='PAYNIA';

select 'recorded as a link payment, attributed to the parent who claimed it' as t,
       history->0->>'trigger_source' = 'link'
   and history->0->>'confirmed_by' = 'pay-parent@t.example' as pass
  from public.cards where share_code='PAYNIA';

select 'with a snapshot, so the owner can undo it like any other' as t,
       history->0->'snapshot' = (select pmts from _before) as pass
  from public.cards where share_code='PAYNIA';

select 'the school is owed EUR150 less than before' as t,
       pg_temp.owed() = (select owed from _before) - 150 as pass;

select 'confirming twice does nothing the second time' as t,
       public.payment_claim_confirm((select id from public.payment_claims
         where card_id='a2000000-0000-0000-0000-0000000000ca'))->>'error' = 'already_decided' as pass;

select 'and the card did not move again' as t,
       jsonb_array_length(history) = 1 as pass
  from public.cards where share_code='PAYNIA';

select 'the queue is empty again' as t,
       jsonb_array_length(public.payment_claims_queue()->'pending') = 0 as pass;

select pg_temp.act_as('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example');
select 'and the parent sees it confirmed' as t,
       public.payment_claims_mine()->0->>'status' = 'confirmed' as pass;


\echo
\echo '=== F. rejecting ==='
select pg_temp.act_as('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example');
create temp table _cl2 as
  select public.payment_claim_create('a2000000-0000-0000-0000-0000000000ca', 50, current_date, 'WRONG') as r;
select 'a second claim can be raised once the first is decided' as t,
       ((select r from _cl2)->>'ok')::boolean as pass;

create temp table _b2 as select (select payments from public.cards where share_code='PAYNIA') as pmts;

select pg_temp.act_as('a0000000-0000-0000-0000-00000000000a','pay-owner@t.example');
select 'rejecting succeeds' as t,
       (public.payment_claim_reject((select id from public.payment_claims where status='pending'),
                                    'Nothing matching that on the statement')->>'ok')::boolean as pass;

select 'and changes nothing on the card' as t,
       payments = (select pmts from _b2) as pass
  from public.cards where share_code='PAYNIA';

select pg_temp.act_as('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example');
select 'the parent is told it was rejected, and why' as t,
       public.payment_claims_mine()->0->>'status' = 'rejected'
   and public.payment_claims_mine()->0->>'note' = 'Nothing matching that on the statement' as pass;


\echo
\echo '=== G. the student portal, which has no login ==='
select pg_temp.act_as(null,null);

select 'a wrong PIN raises nothing' as t,
       public.payment_claim_create_student('PAYKYR','0000', 50, current_date, null)->>'error' = 'no_match' as pass;

create temp table _sc as
  select public.payment_claim_create_student('PAYKYR','5678', 50, current_date, 'CASH-9') as r;
select 'the right code and PIN raises a claim' as t, ((select r from _sc)->>'ok')::boolean as pass;

select 'attributed to the student portal, not to a parent' as t,
       claimed_by = 'student:PAYKYR' as pass
  from public.payment_claims where card_id='a2000000-0000-0000-0000-0000000000cb';

select 'and Kyri''s card is still untouched' as t,
       payments = '{}'::jsonb and history = '[]'::jsonb as pass
  from public.cards where share_code='PAYKYR';

select 'the student sees their own claim' as t,
       jsonb_array_length(public.payment_claims_mine_student('PAYKYR','5678')) = 1 as pass;

select 'but not another student''s' as t,
       public.payment_claims_mine_student('PAYNIA','1234') = '[]'::jsonb as pass;

select pg_temp.act_as('a0000000-0000-0000-0000-00000000000a','pay-owner@t.example');
select 'the school sees it in the same one queue' as t,
       jsonb_array_length(public.payment_claims_queue()->'pending') = 1
   and public.payment_claims_queue()->'pending'->0->>'name' = 'Kyri' as pass;

select 'confirming it writes the same way' as t,
       (public.payment_claim_confirm((select id from public.payment_claims where status='pending'))->>'ok')::boolean as pass;

select 'stamped as a link payment from the student portal' as t,
       history->0->>'trigger_source' = 'link'
   and history->0->>'confirmed_by' = 'student:PAYKYR' as pass
  from public.cards where share_code='PAYKYR';


\echo
\echo '=== H. where the Pay online button points ==='
select pg_temp.act_as('a0000000-0000-0000-0000-0000000000c0','pay-parent@t.example');
select 'a parent is given their school''s link' as t,
       jsonb_array_length(public.payment_links_mine()) = 1
   and public.payment_links_mine()->0->>'link' = 'https://revolut.me/antonis'
   and public.payment_links_mine()->0->>'name' = 'Revolut — Antonis' as pass;

select pg_temp.act_as('a0000000-0000-0000-0000-0000000000d0','pay-stranger@t.example');
select 'somebody with no children is given nothing' as t,
       public.payment_links_mine() = '[]'::jsonb as pass;

select pg_temp.act_as(null,null);
select 'a logged-out caller is given nothing' as t,
       public.payment_links_mine() = '[]'::jsonb as pass;

select 'the student portal gets it with the right code and PIN' as t,
       public.payment_link_student('PAYNIA','1234')->>'link' = 'https://revolut.me/antonis' as pass;

select 'and nothing with a wrong PIN' as t,
       public.payment_link_student('PAYNIA','0000')->>'link' is null as pass;

select 'a school that has set none offers none' as t,
       public.payment_link_student('PAYNOL','8888')->>'link' is null as pass;

\echo
\echo '=== I. grants ==='

select 'the claims table is function-internal' as t, count(*) = 0 as pass
  from information_schema.role_table_grants
 where table_name = 'payment_claims' and grantee in ('anon','authenticated');

select 'payment_claim_open proves nothing itself and is callable by nobody' as t,
       count(*) = 0 as pass
  from pg_proc p where p.proname = 'payment_claim_open'
   and (has_function_privilege('anon', p.oid, 'execute')
     or has_function_privilege('authenticated', p.oid, 'execute'));

select 'anon reaches only the three student-portal payment functions' as t,
       array_agg(p.proname order by p.proname) = array[
         'payment_claim_create_student','payment_claims_mine_student','payment_link_student'
       ]::name[] as pass
  from pg_proc p
 where p.proname like 'payment_%' and has_function_privilege('anon', p.oid, 'execute');

select 'the owner may set the link, but not the plan' as t,
       array_agg(column_name::text order by column_name) @> array['payment_link','payment_link_name']
   and not (array_agg(column_name::text order by column_name) @> array['plan']) as pass
  from information_schema.column_privileges
 where table_name='businesses' and grantee='authenticated' and privilege_type='UPDATE';
