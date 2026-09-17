-- ===========================================================================
--  PUSH NOTIFICATIONS
--
--  The question that matters here is not "does a push arrive" -- no SQL suite
--  can answer that -- but "who is it sent to". An endpoint is a capability to
--  make somebody's phone buzz, and push_audience hands them out, so:
--
--    A. a parent may subscribe their own browser and nobody else's
--    B. THE AUDIENCE RULES MATCH THE ANNOUNCEMENT'S OWN
--    C. nobody but the service role can ask who is subscribed
--
--  B is the one that will rot. The rules are written down in three places now
--  -- get_my_announcements, the portal's filter, and push_audience -- so they
--  are asserted here against the same three cases the portal draws.
-- ===========================================================================

\set ON_ERROR_STOP off
set search_path = public, extensions;

-- SESSION scope, not local. `set_config(..., true)` and `set local` last only
-- to the end of the transaction, and in autocommit that is the end of the
-- statement -- so the claims were gone again before the next assertion ran and
-- every auth-dependent verdict came back NULL. The other suites already got
-- this right; this one did not, and the rig's NULL counting is what caught it.
create or replace function pg_temp.act_as(p_uid text, p_email text)
returns void language sql as $$
  select set_config('request.jwt.claim.sub',   coalesce(p_uid,''),   false),
         set_config('request.jwt.claim.email', coalesce(p_email,''), false);
  select null::void;
$$;

-- The sender runs with the service role and no JWT at all.
create or replace function pg_temp.act_as_service()
returns void language sql as $$
  select set_config('request.jwt.claim.sub','',false),
         set_config('request.jwt.claim.email','',false);
  select null::void;
$$;


-- --------------------------------------------------------------------------
--  Fixture: one school, two classes, three students, three parents.
-- --------------------------------------------------------------------------
insert into auth.users(id, email) values
  ('d0000000-0000-0000-0000-00000000000a','push-owner@t.example'),
  ('d0000000-0000-0000-0000-0000000000c0','push-mum@t.example'),
  ('d0000000-0000-0000-0000-0000000000c1','push-dad@t.example'),
  ('d0000000-0000-0000-0000-0000000000c2','push-other@t.example')
on conflict do nothing;

insert into public.businesses(id, owner_id, biz_code, name, type, fee, year)
values ('d1000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-00000000000a',
        'PUSH01','Push Dance School','Dance',50,2026)
on conflict do nothing;

insert into public.groups(id, business_id, name) values
  ('d3000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','Sharks'),
  ('d3000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000001','Dolphins')
on conflict do nothing;

insert into public.cards(id, business_id, name, share_code, pin, group_id) values
  ('d2000000-0000-0000-0000-0000000000ca','d1000000-0000-0000-0000-000000000001','Afrodite','PUSHA','1111','d3000000-0000-0000-0000-000000000001'),
  ('d2000000-0000-0000-0000-0000000000cb','d1000000-0000-0000-0000-000000000001','Anais','PUSHB','2222','d3000000-0000-0000-0000-000000000002'),
  ('d2000000-0000-0000-0000-0000000000cc','d1000000-0000-0000-0000-000000000001','Loukas','PUSHC','3333','d3000000-0000-0000-0000-000000000001')
on conflict do nothing;

-- mum has both her children; dad has the third. "other" is at no school here.
insert into public.card_links(card_id, parent_email) values
  ('d2000000-0000-0000-0000-0000000000ca','push-mum@t.example'),
  ('d2000000-0000-0000-0000-0000000000cb','push-mum@t.example'),
  ('d2000000-0000-0000-0000-0000000000cc','push-dad@t.example')
on conflict do nothing;


\echo
\echo '=== A. a parent subscribes their own browser ==='
select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c0','push-mum@t.example');

select 'a parent can subscribe a browser' as t,
       (public.push_subscribe('https://push.example.com/ep/mum-phone','PK1','AK1','iPhone')->>'ok')::boolean as pass;

select 'and a second one, because a phone and a laptop should both ring' as t,
       (public.push_subscribe('https://push.example.com/ep/mum-laptop','PK2','AK2','Mac')->>'ok')::boolean as pass;

select 'both are stored against them' as t, count(*) = 2 as pass
  from public.push_subscriptions where parent_email = 'push-mum@t.example';

select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c0','push-mum@t.example');
select 'subscribing the same browser twice does not make two rows' as t,
       (public.push_subscribe('https://push.example.com/ep/mum-phone','PK1b','AK1b','iPhone')->>'ok')::boolean as pass;
select 'still two' as t, count(*) = 2 as pass
  from public.push_subscriptions where parent_email = 'push-mum@t.example';
select 'and the keys were refreshed rather than kept' as t, p256dh = 'PK1b' as pass
  from public.push_subscriptions where endpoint = 'https://push.example.com/ep/mum-phone';

select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c1','push-dad@t.example');
select 'another parent subscribes their own' as t,
       (public.push_subscribe('https://push.example.com/ep/dad-phone','PK3','AK3',null)->>'ok')::boolean as pass;

-- A second-hand phone is the case this covers: the endpoint is the browser's,
-- so whoever signs in on it now is who it belongs to.
select 'taking over an endpoint moves it, rather than ringing for both' as t,
       (public.push_subscribe('https://push.example.com/ep/mum-laptop','PK4','AK4',null)->>'ok')::boolean as pass;
select 'the endpoint now belongs to whoever subscribed it last' as t,
       parent_email = 'push-dad@t.example' as pass
  from public.push_subscriptions where endpoint = 'https://push.example.com/ep/mum-laptop';
select 'and there is still only one row for it' as t, count(*) = 1 as pass
  from public.push_subscriptions where endpoint = 'https://push.example.com/ep/mum-laptop';

-- Put it back where it was, so the audience counts below are about targeting.
select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c0','push-mum@t.example');
select public.push_subscribe('https://push.example.com/ep/mum-laptop','PK2','AK2','Mac') is not null as _setup;

select 'rubbish is refused rather than stored' as t,
       public.push_subscribe('not-a-url','PK','AK')->>'error' = 'bad_endpoint' as pass;
select 'and so is a plain-http endpoint' as t,
       public.push_subscribe('http://push.example.com/x','PK','AK')->>'error' = 'bad_endpoint' as pass;

select 'a parent can ask about their own browser' as t,
       (public.push_status('https://push.example.com/ep/mum-phone')->>'on')::boolean as pass;
select 'and gets a plain no for a browser that is not theirs' as t,
       (public.push_status('https://push.example.com/ep/dad-phone')->>'on')::boolean = false as pass;

select 'they cannot unsubscribe somebody else''s browser' as t,
       (public.push_unsubscribe('https://push.example.com/ep/dad-phone')->>'ok')::boolean as pass;
select 'which is to say it is still there' as t, count(*) = 1 as pass
  from public.push_subscriptions where endpoint = 'https://push.example.com/ep/dad-phone';


\echo
\echo '=== B. THE AUDIENCE RULES MATCH THE ANNOUNCEMENT''S OWN ==='
insert into public.announcements(id, business_id, title, body) values
  ('d4000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','Whole school','Closed Monday')
on conflict do nothing;
insert into public.announcements(id, business_id, title, body, group_id) values
  ('d4000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000001','Sharks only','Moves to Thursday','d3000000-0000-0000-0000-000000000001')
on conflict do nothing;
insert into public.announcements(id, business_id, title, body, card_id) values
  ('d4000000-0000-0000-0000-000000000003','d1000000-0000-0000-0000-000000000001','Just Anais','Bring shoes','d2000000-0000-0000-0000-0000000000cb')
on conflict do nothing;

select pg_temp.act_as_service();

-- Mum has two browsers, dad one. Everyone is in the whole-school audience.
select 'a whole-school note reaches every subscribed parent at that school' as t,
       jsonb_array_length(public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') = 3 as pass;

-- Sharks is Afrodite (mum) and Loukas (dad). Both, so still three browsers.
select 'a class note reaches the parents of that class' as t,
       jsonb_array_length(public.push_audience('d4000000-0000-0000-0000-000000000002')->'subscriptions') = 3 as pass;

-- Anais is mum's alone: her two browsers, and not dad's.
select 'a note for one student reaches only that student''s parents' as t,
       jsonb_array_length(public.push_audience('d4000000-0000-0000-0000-000000000003')->'subscriptions') = 2 as pass;

select 'and dad''s browser is NOT in it' as t,
       not exists (
         select 1 from jsonb_array_elements(
           public.push_audience('d4000000-0000-0000-0000-000000000003')->'subscriptions') s
          where s->>'endpoint' = 'https://push.example.com/ep/dad-phone') as pass;

select 'the notification carries the school''s name and the headline' as t,
       (public.push_audience('d4000000-0000-0000-0000-000000000001')->>'school') = 'Push Dance School'
   and (public.push_audience('d4000000-0000-0000-0000-000000000001')->>'title') = 'Whole school' as pass;

select 'and each subscription carries the keys needed to encrypt to it' as t,
       (select bool_and((s->>'p256dh') is not null and (s->>'auth') is not null)
          from jsonb_array_elements(
            public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s) as pass;

-- A parent at another school entirely must never appear.
select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c2','push-other@t.example');
select public.push_subscribe('https://push.example.com/ep/other','PK9','AK9',null) is not null as _setup;
select pg_temp.act_as_service();
select 'somebody with no child at this school hears nothing' as t,
       jsonb_array_length(public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') = 3 as pass;

-- Switched off, or already expired: not news, and nothing is sent.
update public.announcements set is_active = false
 where id = 'd4000000-0000-0000-0000-000000000002';
select pg_temp.act_as_service();
select 'an announcement that is switched off is not sent' as t,
       public.push_audience('d4000000-0000-0000-0000-000000000002')->>'error' = 'not_active' as pass;

update public.announcements set is_active = true, expires_at = now() - interval '1 day'
 where id = 'd4000000-0000-0000-0000-000000000002';
select pg_temp.act_as_service();
select 'nor is one that has already expired' as t,
       public.push_audience('d4000000-0000-0000-0000-000000000002')->>'error' = 'not_active' as pass;

select 'an announcement that does not exist is not an error to guess at' as t,
       public.push_audience('d4000000-0000-0000-0000-0000000000ff')->>'error' = 'no_match' as pass;


\echo
\echo '=== B2. the number on the app icon ==='
-- A badge that disagrees with what is inside the app is worse than no badge,
-- so it is this parent's unread count by the portal's own rules -- not "how
-- many pushes we sent", which is what counting in the browser would give.
-- Section B left the Sharks note switched off and expired, which would make
-- the numbers below depend on what ran before them. Put it back, so this
-- section's counts can be read off its own fixture.
update public.announcements set is_active = true, expires_at = null
 where id = 'd4000000-0000-0000-0000-000000000002';
select pg_temp.act_as_service();

select 'a subscription carries a badge count' as t,
       (select (s->>'badge') is not null
          from jsonb_array_elements(
            public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
         limit 1) as pass;

-- Mum has two children at this school and three notes exist: one for the whole
-- school, one for Sharks (Afrodite), one just for Anais. All three reach her.
select 'and it counts every note that reaches them' as t,
       (select (s->>'badge')::int = 3
          from jsonb_array_elements(
            public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
         where s->>'endpoint' = 'https://push.example.com/ep/mum-phone') as pass;

-- Dad has one child in Sharks: the whole-school note and the Sharks note, not
-- the one for Anais.
select 'counted per person, not per school' as t,
       (select (s->>'badge')::int = 2
          from jsonb_array_elements(
            public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
         where s->>'endpoint' = 'https://push.example.com/ep/dad-phone') as pass;

-- Reading one drops the count, which is what makes the badge follow the app.
insert into public.announcement_reads(parent_id, announcement_id)
  values ('d0000000-0000-0000-0000-0000000000c0','d4000000-0000-0000-0000-000000000001')
on conflict do nothing;
select pg_temp.act_as_service();
select 'reading one takes it off the count' as t,
       (select (s->>'badge')::int = 2
          from jsonb_array_elements(
            public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
         where s->>'endpoint' = 'https://push.example.com/ep/mum-phone') as pass;
select 'and only for the person who read it' as t,
       (select (s->>'badge')::int = 2
          from jsonb_array_elements(
            public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
         where s->>'endpoint' = 'https://push.example.com/ep/dad-phone') as pass;

select 'somebody with no children at this school is not in it at all' as t,
       not exists (
         select 1 from jsonb_array_elements(
           public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
          where s->>'endpoint' = 'https://push.example.com/ep/other') as pass;

-- The count is one person's business, so nobody else may ask for it.
select 'a parent cannot ask what anybody is unread on' as t,
       (select not has_function_privilege('authenticated','public.push_unread_count(text)','execute')
           and not has_function_privilege('anon','public.push_unread_count(text)','execute')) as pass;


\echo
\echo '=== C. a dead endpoint stops being tried ==='
select pg_temp.act_as_service();
select 'the sender can mark an endpoint gone' as t,
       (public.push_mark_gone('https://push.example.com/ep/dad-phone')->>'ok')::boolean as pass;
select 'and it drops out of every audience from then on' as t,
       not exists (
         select 1 from jsonb_array_elements(
           public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') s
          where s->>'endpoint' = 'https://push.example.com/ep/dad-phone') as pass;
select 'leaving two' as t,
       jsonb_array_length(public.push_audience('d4000000-0000-0000-0000-000000000001')->'subscriptions') = 2 as pass;

-- Kept, not deleted, so "why did this phone stop ringing" has an answer.
select 'the row is kept, with the reason' as t, gone_at is not null as pass
  from public.push_subscriptions where endpoint = 'https://push.example.com/ep/dad-phone';

-- And subscribing again revives it -- turning notifications back on must work.
select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c1','push-dad@t.example');
select 'subscribing again brings it back' as t,
       (public.push_subscribe('https://push.example.com/ep/dad-phone','PK3','AK3',null)->>'ok')::boolean as pass;
select 'and it is no longer marked gone' as t, gone_at is null as pass
  from public.push_subscriptions where endpoint = 'https://push.example.com/ep/dad-phone';


\echo
\echo '=== D. nobody may ask who is subscribed ==='
select pg_temp.act_as('d0000000-0000-0000-0000-0000000000c0','push-mum@t.example');

-- An endpoint is a capability to make somebody's phone buzz. A parent who
-- could read the table could buzz every family in the school.
select 'a parent cannot select the table' as t,
       (select not has_table_privilege('authenticated','public.push_subscriptions','select')) as pass;
select 'nor insert into it directly, going round the checks' as t,
       (select not has_table_privilege('authenticated','public.push_subscriptions','insert')) as pass;

select 'a parent cannot ask for an audience' as t,
       (select not has_function_privilege('authenticated','public.push_audience(uuid)','execute')) as pass;
select 'nor can anon' as t,
       (select not has_function_privilege('anon','public.push_audience(uuid)','execute')) as pass;
select 'the service role can, because the sender is the only caller' as t,
       (select has_function_privilege('service_role','public.push_audience(uuid)','execute')) as pass;

select 'a parent cannot mark other people''s endpoints dead' as t,
       (select not has_function_privilege('authenticated','public.push_mark_gone(text)','execute')) as pass;

select 'but may subscribe, unsubscribe and check their own' as t,
       (select has_function_privilege('authenticated','public.push_subscribe(text,text,text,text)','execute')
           and has_function_privilege('authenticated','public.push_unsubscribe(text)','execute')
           and has_function_privilege('authenticated','public.push_status(text)','execute')) as pass;

select 'and anon may do none of it' as t,
       (select not has_function_privilege('anon','public.push_subscribe(text,text,text,text)','execute')) as pass;

-- Signed out, the functions refuse rather than acting on a null email.
select pg_temp.act_as(null, null);
select 'signed out, subscribing is refused' as t,
       public.push_subscribe('https://push.example.com/ep/x','P','A')->>'error' = 'not_authenticated' as pass;


\echo
\echo '=== E. it touched nothing outside itself ==='
select 'one table was added' as t, count(*) = 1 as pass
  from information_schema.tables
 where table_schema = 'public' and table_name = 'push_subscriptions';

select 'and six functions, all prefixed push_' as t, count(*) = 6 as pass
  from pg_proc where proname like 'push\_%';

-- The announcements table is what this reads. If it were altered, removing
-- notifications would mean putting something back.
select 'announcements was not altered' as t,
       count(*) filter (where column_name like 'push%') = 0 as pass
  from information_schema.columns
 where table_schema = 'public' and table_name = 'announcements';
