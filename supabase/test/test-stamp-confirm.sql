-- Trigger-agnostic payment confirmation (migration-stamp-confirm.sql).
-- Verdicts are the `pass` column: t or f. Run via ./run-tests.sh.
--
-- The point of most of these is not that the happy path works -- it is that
-- the unhappy ones are refused. A parent holds the phone that calls these
-- functions, and the only thing standing between a tap and an arbitrary write
-- to public.cards is what stamp_confirm decides to do.

\set ON_ERROR_STOP off

\echo '=== fixtures ==='
insert into auth.users(id,email) values
  ('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example'),
  ('50000000-0000-0000-0000-00000000000b','stamp-owner-b@t.example'),
  ('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example'),
  ('50000000-0000-0000-0000-0000000000d0','stamp-other@t.example');

-- Two schools. Fee 50, July and August closed (months 6 and 7).
insert into public.businesses(id,owner_id,biz_code,name,type,fee,year,approval_status,inactive_months) values
  ('51000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-00000000000a','STP-A','Stamp School A','Swimming',50,2026,'approved','[6,7]'),
  ('51000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-00000000000b','STP-B','Stamp School B','Music',30,2026,'approved','[]');

-- One student at each school. Anna owes everything; Boris belongs to B.
insert into public.cards(id,business_id,name,share_code,pin,payments,history) values
  ('52000000-0000-0000-0000-0000000000ca','51000000-0000-0000-0000-000000000001','Anna','STPANNA','1111','{}','[]'),
  ('52000000-0000-0000-0000-0000000000cb','51000000-0000-0000-0000-000000000002','Boris','STPBORIS','2222','{}','[]');

-- The parent is linked to Anna only.
insert into public.card_links(card_id,parent_email) values
  ('52000000-0000-0000-0000-0000000000ca','stamp-parent@t.example');

create or replace function pg_temp.act_as(p_uid text, p_email text) returns void
language sql as $$
  select set_config('request.jwt.claim.sub',   coalesce(p_uid,''),   false),
         set_config('request.jwt.claim.email', coalesce(p_email,''), false);
  select null::void;
$$;

create or replace function pg_temp.tok() returns text language sql as $$
  select token from public.stamp_tokens
   where business_id='51000000-0000-0000-0000-000000000001' and revoked_at is null;
$$;


\echo
\echo '=== A. the token ==='
select pg_temp.act_as('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example');

select 'first call mints a token' as t,
       (public.stamp_token_get()->>'ok')::boolean and length(public.stamp_token_get()->>'token') >= 20 as pass;

create temp table _t1 as select public.stamp_token_get()->>'token' as tok;
select 'calling again returns the same one, not a new one' as t,
       (select tok from _t1) = (public.stamp_token_get()->>'token') as pass;

select 'the token is URL-safe' as t,
       (public.stamp_token_get()->>'token') !~ '[+/=]' as pass;

create temp table _t2 as select public.stamp_token_rotate()->>'token' as tok;
select 'rotating issues a different token' as t,
       (select tok from _t1) <> (select tok from _t2) as pass;

select 'the old token is revoked, not deleted' as t, count(*) = 1 as pass
  from public.stamp_tokens
 where business_id='51000000-0000-0000-0000-000000000001' and revoked_at is not null;

select 'exactly one token is active at a time' as t, count(*) = 1 as pass
  from public.stamp_tokens
 where business_id='51000000-0000-0000-0000-000000000001' and revoked_at is null;

select 'a school with no business gets no token' as t,
       public.stamp_token_get()->>'error' = 'no_business' as pass
  from (select pg_temp.act_as('50000000-0000-0000-0000-0000000000d0','stamp-other@t.example')) _;


\echo
\echo '=== B. who is holding the phone ==='
select pg_temp.act_as(null,null);
select 'a logged-out tap is told to log in' as t,
       public.stamp_begin(pg_temp.tok())->>'error' = 'not_authenticated' as pass;

select pg_temp.act_as('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example');
select 'the owner''s own device gets the business view' as t,
       (public.stamp_begin(pg_temp.tok())->>'owner')::boolean as pass;

select 'and nothing is recorded for it' as t, count(*) = 0 as pass
  from public.stamp_confirmations;

select pg_temp.act_as('50000000-0000-0000-0000-0000000000d0','stamp-other@t.example');
select 'someone who is not a customer gets no_match' as t,
       public.stamp_begin(pg_temp.tok())->>'error' = 'no_match' as pass;

select pg_temp.act_as('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example');
select 'a made-up token gets the SAME answer, so it cannot be probed' as t,
       public.stamp_begin('not-a-real-token-at-all')->>'error' = 'no_match' as pass;

select 'a real parent gets a session' as t,
       (public.stamp_begin(pg_temp.tok())->>'ok')::boolean as pass;

select 'the session names their child and prefills a month' as t,
       s->>'name' = 'Anna' and s->>'month' = 'January' and (s->>'amount')::numeric = 50 as pass
  from (select jsonb_array_elements(public.stamp_begin(pg_temp.tok())->'students') as s) _;

select 'the session lasts 60 seconds' as t,
       expires_at - created_at = interval '60 seconds' as pass
  from public.stamp_confirmations order by created_at desc limit 1;


\echo
\echo '=== C. a revoked token stops working immediately ==='
create temp table _live as select pg_temp.tok() as tok;
select pg_temp.act_as('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example');
select 'revoke succeeds' as t, (public.stamp_token_revoke()->>'ok')::boolean as pass;
select pg_temp.act_as('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example');
select 'the tag that worked a moment ago now resolves to nothing' as t,
       public.stamp_begin((select tok from _live))->>'error' = 'no_match' as pass;

-- Put a live token back for the rest of the suite.
select pg_temp.act_as('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example');
select public.stamp_token_rotate() is not null as _setup;


\echo
\echo '=== D. the arithmetic matches the dashboard ==='
select pg_temp.act_as('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example');

create temp table _c1 as select public.stamp_begin(pg_temp.tok()) as r;
create temp table _r1 as
  select public.stamp_confirm(
           ((select r from _c1)->>'confirmation')::uuid,
           '52000000-0000-0000-0000-0000000000ca', 125) as r;

select 'EUR125 at EUR50/month covers two months and part-pays the third' as t,
       ((select r from _r1)->'months') = '[0,1,2]'::jsonb as pass;

select 'January and February read as paid in full' as t,
       (payments->'2026-01'->>'paid')::boolean
   and (payments->'2026-02'->>'paid')::boolean
   and (payments->'2026-01'->>'amount')::numeric = 50 as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

select 'March carries the EUR25 remainder as partial' as t,
       (payments->'2026-03'->>'paid')::boolean = false
   and (payments->'2026-03'->>'partial')::boolean
   and (payments->'2026-03'->>'amount')::numeric = 25 as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

select 'the history entry carries a snapshot, so undo has something to restore' as t,
       history->0->'snapshot' = '{}'::jsonb and (history->0->>'n')::int = 1 as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

select 'and it is stamped with how it was triggered' as t,
       history->0->>'trigger_source' = 'nfc'
   and history->0->>'confirmed_by' = 'stamp-parent@t.example' as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

-- The next tap should pick up where the last one left off.
create temp table _c2 as select public.stamp_begin(pg_temp.tok()) as r;
select 'the next tap prefills the EUR25 still owed on March, not a full fee' as t,
       s->>'month' = 'March' and (s->>'amount')::numeric = 25 as pass
  from (select jsonb_array_elements((select r from _c2)->'students') as s) _;

select 'closed months are skipped entirely' as t,
       not (payments ? '2026-07') and not (payments ? '2026-08') as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';


\echo
\echo '=== E. what a hostile parent cannot do ==='

select 'the same session cannot be spent twice' as t,
       public.stamp_confirm(((select r from _c1)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000ca', 500)->>'error' = 'expired' as pass;

select 'and the replay wrote nothing' as t,
       (payments->'2026-04'->>'amount') is null as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

create temp table _c3 as select public.stamp_begin(pg_temp.tok()) as r;
select 'a session cannot be pointed at another school''s student' as t,
       public.stamp_confirm(((select r from _c3)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000cb', 30)->>'error' = 'no_match' as pass;

select 'nor at a child this parent is not linked to' as t, count(*) = 0 as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000cb'
   and payments <> '{}'::jsonb;

create temp table _c4 as select public.stamp_begin(pg_temp.tok()) as r;
select pg_temp.act_as('50000000-0000-0000-0000-0000000000d0','stamp-other@t.example');
select 'somebody else cannot spend a session that is not theirs' as t,
       public.stamp_confirm(((select r from _c4)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000ca', 50)->>'error' = 'expired' as pass;

select pg_temp.act_as('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example');
select 'a zero or negative amount is refused' as t,
       public.stamp_confirm(((select r from _c4)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000ca', -100)->>'error' = 'bad_amount' as pass;

-- The function takes an amount and nothing else. There is no parameter that
-- could carry a payments blob, which is the property that matters most here.
select 'stamp_confirm accepts no caller-supplied payments structure' as t,
       pg_get_function_arguments(oid) = 'p_confirmation uuid, p_card_id uuid, p_amount numeric, p_pin text DEFAULT NULL::text' as pass
  from pg_proc where proname = 'stamp_confirm';

create temp table _cx as select (public.stamp_begin(pg_temp.tok())->>'confirmation')::uuid as id;
update public.stamp_confirmations set expires_at = now() - interval '1 second'
 where id = (select id from _cx);
select 'a session older than 60 seconds is refused' as t,
       public.stamp_confirm((select id from _cx),
                            '52000000-0000-0000-0000-0000000000ca', 50)->>'error' = 'expired' as pass;


\echo
\echo '=== F. the PIN ==='
select pg_temp.act_as('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example');

select 'the requirement cannot be switched on before a PIN exists' as t,
       public.set_confirm_settings(true, null)->>'error' = 'pin_required' as pass;

select 'a non-numeric PIN is refused' as t,
       public.set_confirm_settings(false, 'abcd')->>'error' = 'bad_pin' as pass;

select 'setting a PIN and the requirement together works' as t,
       (public.set_confirm_settings(true, '4242')->>'ok')::boolean as pass;

select pg_temp.act_as('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example');
create temp table _c5 as select public.stamp_begin(pg_temp.tok()) as r;

select 'the session says a PIN will be wanted' as t,
       ((select r from _c5)->>'require_pin')::boolean as pass;

select 'confirming without the PIN is refused' as t,
       public.stamp_confirm(((select r from _c5)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000ca', 50)->>'error' = 'bad_pin' as pass;

select 'a wrong PIN does not cost the session' as t,
       public.stamp_confirm(((select r from _c5)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000ca', 50, '9999')->>'error' = 'bad_pin' as pass;

select 'the third wrong try burns it' as t,
       (public.stamp_confirm(((select r from _c5)->>'confirmation')::uuid,
                             '52000000-0000-0000-0000-0000000000ca', 50, '9999')->>'burned')::boolean as pass;

select 'after which even the right PIN will not spend it' as t,
       public.stamp_confirm(((select r from _c5)->>'confirmation')::uuid,
                            '52000000-0000-0000-0000-0000000000ca', 50, '4242')->>'error' = 'expired' as pass;

create temp table _c6 as select public.stamp_begin(pg_temp.tok()) as r;
select 'a fresh session with the right PIN goes through' as t,
       (public.stamp_confirm(((select r from _c6)->>'confirmation')::uuid,
                             '52000000-0000-0000-0000-0000000000ca', 25, '4242')->>'ok')::boolean as pass;

select 'which finished off March' as t,
       (payments->'2026-03'->>'paid')::boolean and (payments->'2026-03'->>'amount')::numeric = 50 as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

select pg_temp.act_as('50000000-0000-0000-0000-00000000000a','stamp-owner-a@t.example');
select 'the PIN is never handed back out' as t,
       (public.stamp_token_get() ? 'confirm_pin') = false
   and (public.stamp_token_get()->>'pin_set')::boolean as pass;
select public.set_confirm_settings(false, null) is not null as _setup;


\echo
\echo '=== G. QR taps are told apart from NFC taps, by the server ==='
select pg_temp.act_as('50000000-0000-0000-0000-0000000000c0','stamp-parent@t.example');

select 'no nonce means it came off a tag' as t,
       public.stamp_begin(pg_temp.tok())->>'trigger' = 'nfc' as pass;

select 'a nonce for the current 30-second window means it came off a screen' as t,
       public.stamp_begin(pg_temp.tok(),
         public.stamp_nonce_for(pg_temp.tok(), floor(extract(epoch from now())/30)::bigint)
       )->>'trigger' = 'qr' as pass;

select 'one window of clock slack either side is tolerated' as t,
       public.stamp_nonce_valid(pg_temp.tok(),
         public.stamp_nonce_for(pg_temp.tok(), floor(extract(epoch from now())/30)::bigint - 1)) as pass;

select 'a stale nonce is not' as t,
       public.stamp_nonce_valid(pg_temp.tok(),
         public.stamp_nonce_for(pg_temp.tok(), floor(extract(epoch from now())/30)::bigint - 5)) = false as pass;

select 'a nonce minted for a different token does not validate' as t,
       public.stamp_nonce_valid(pg_temp.tok(),
         public.stamp_nonce_for('some-other-token', floor(extract(epoch from now())/30)::bigint)) = false as pass;

select 'the browser cannot simply declare which it was' as t,
       public.stamp_begin(pg_temp.tok(), 'qr')->>'trigger' = 'nfc' as pass;


\echo
\echo '=== H. undo ==='
create temp table _c7 as select public.stamp_begin(pg_temp.tok()) as r;
create temp table _r7 as
  select public.stamp_confirm(((select r from _c7)->>'confirmation')::uuid,
                              '52000000-0000-0000-0000-0000000000ca', 50) as r;

create temp table _before as
  select payments, history from public.cards where id='52000000-0000-0000-0000-0000000000ca';

select 'a parent can undo the entry they just made' as t,
       (public.stamp_undo('52000000-0000-0000-0000-0000000000ca',
                          ((select r from _r7)->>'n')::int)->>'ok')::boolean as pass;

select 'the payments go back exactly as they were' as t,
       c.payments = ((select history from _before)->0->'snapshot') as pass
  from public.cards c where c.id='52000000-0000-0000-0000-0000000000ca';

select 'and the entry is gone from the history' as t,
       jsonb_array_length(history) = jsonb_array_length((select history from _before)) - 1 as pass
  from public.cards where id='52000000-0000-0000-0000-0000000000ca';

select 'undoing again does nothing, because that entry is no longer the newest' as t,
       public.stamp_undo('52000000-0000-0000-0000-0000000000ca',
                         ((select r from _r7)->>'n')::int)->>'error' = 'cannot_undo' as pass;

-- Something the owner typed into the dashboard has no trigger_source, and is
-- theirs to undo, not the parent's.
update public.cards
   set history = jsonb_build_array(jsonb_build_object(
         'n', 99, 'amount', 10, 'date', '01/01/2026', 'snapshot', payments, 'months', '[5]'::jsonb))
       || history
 where id='52000000-0000-0000-0000-0000000000ca';

select 'a parent cannot undo a payment the owner recorded by hand' as t,
       public.stamp_undo('52000000-0000-0000-0000-0000000000ca', 99)->>'error' = 'cannot_undo' as pass;

select pg_temp.act_as('50000000-0000-0000-0000-0000000000d0','stamp-other@t.example');
select 'and cannot undo anything on a child that is not theirs' as t,
       public.stamp_undo('52000000-0000-0000-0000-0000000000ca', 99)->>'error' = 'no_match' as pass;


\echo
\echo '=== I. grants ==='
-- The parentheses matter: without them AND binds tighter than OR and this
-- counts every stamp function regardless of privilege, which is a test that
-- cannot pass rather than one that cannot fail -- but the same shape written
-- the other way round is the classic green-on-nothing bug.
select 'anon cannot call any of the stamp functions' as t, count(*) = 0 as pass
  from pg_proc p
 where (p.proname like 'stamp%' or p.proname = 'set_confirm_settings')
   and has_function_privilege('anon', p.oid, 'execute');

select 'but a logged-in caller can reach the seven public ones' as t, count(*) = 7 as pass
  from pg_proc p
 where (p.proname like 'stamp%' or p.proname = 'set_confirm_settings')
   and has_function_privilege('authenticated', p.oid, 'execute');

select 'the arithmetic helpers are not callable from outside at all' as t,
       count(*) = 0 as pass
  from pg_proc p
 where p.proname in ('stamp_calc_breakdown','stamp_fee_for_month','stamp_new_token_value',
                     'stamp_nonce_for','stamp_nonce_valid')
   and (has_function_privilege('anon', p.oid, 'execute')
     or has_function_privilege('authenticated', p.oid, 'execute'));

select 'the two new tables are function-internal' as t, count(*) = 0 as pass
  from information_schema.role_table_grants
 where table_name in ('stamp_tokens','stamp_confirmations')
   and grantee in ('anon','authenticated');
