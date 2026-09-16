-- School shop module (migration-shop.sql).
-- Verdicts are the `pass` column: t or f. Run via ./run-tests.sh.
--
-- Three things this file exists to hold down, in order of how much they would
-- cost if they broke:
--
--   B. Shop orders do not touch the fee ledger. "Who owes me for September" is
--      a question about lessons; a debt for shoes is a different question. The
--      assertion photographs the card and the school's owed total before and
--      after an order and compares them, rather than reading the code.
--   E. Stock cannot oversell. Checked and decremented in one statement, so two
--      parents reaching for the last jumper cannot both get it.
--   G. Off means absent. A school with the shop disabled offers a parent
--      nothing at all -- not an empty catalogue, nothing.

\set ON_ERROR_STOP off

\echo '=== fixtures ==='
insert into auth.users(id,email) values
  ('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example'),
  ('c0000000-0000-0000-0000-00000000000b','shop-other@t.example'),
  ('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example'),
  ('c0000000-0000-0000-0000-0000000000c1','shop-parent2@t.example'),
  ('c0000000-0000-0000-0000-0000000000d0','shop-stranger@t.example');

insert into public.businesses(id,owner_id,biz_code,name,type,fee,year,approval_status) values
  ('c1000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000a','SHP-A','Shop School','Dance',50,2026,'approved'),
  ('c1000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-00000000000b','SHP-B','Other School','Music',40,2026,'approved');

insert into public.cards(id,business_id,name,share_code,pin,payments,history) values
  ('c2000000-0000-0000-0000-0000000000ca','c1000000-0000-0000-0000-000000000001','Ira','SHPIRA','1111','{}','[]'),
  ('c2000000-0000-0000-0000-0000000000cb','c1000000-0000-0000-0000-000000000001','Loukas','SHPLOU','2222','{}','[]'),
  ('c2000000-0000-0000-0000-0000000000cc','c1000000-0000-0000-0000-000000000002','Foreign','SHPFOR','3333','{}','[]');

insert into public.card_links(card_id,parent_email) values
  ('c2000000-0000-0000-0000-0000000000ca','shop-parent@t.example'),
  ('c2000000-0000-0000-0000-0000000000cb','shop-parent2@t.example');

create or replace function pg_temp.act_as(p_uid text, p_email text) returns void
language sql as $$
  select set_config('request.jwt.claim.sub',   coalesce(p_uid,''),   false),
         set_config('request.jwt.claim.email', coalesce(p_email,''), false);
  select null::void;
$$;

-- The fee ledger, totalled the way the dashboard totals it.
create or replace function pg_temp.fees_owed() returns numeric language sql as $$
  select coalesce(sum(
    (select count(*) from generate_series(0,11) mi
      where not (b.inactive_months @> to_jsonb(mi))
        and not coalesce((c.payments -> (b.year::text||'-'||lpad((mi+1)::text,2,'0')) ->> 'paid')::boolean, false)
    ) * b.fee), 0)
  from public.cards c join public.businesses b on b.id = c.business_id
 where b.biz_code = 'SHP-A';
$$;


\echo
\echo '=== A. the switch, and that off means absent ==='
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');

select 'a school starts with no shop' as t,
       (public.shop_settings_get()->>'enabled')::boolean = false as pass;

select 'and no row is needed for that to be true' as t, count(*) = 0 as pass
  from public.shop_settings;

select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');
select 'a parent of that school is offered nothing at all' as t,
       public.shop_catalogue_mine() = '[]'::jsonb as pass;

select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select 'switching it on works' as t,
       (public.shop_settings_set(true)->>'enabled')::boolean as pass;

select pg_temp.act_as('c0000000-0000-0000-0000-0000000000d0','shop-stranger@t.example');
select 'somebody with no business cannot switch one on' as t,
       public.shop_settings_set(true)->>'error' = 'no_business' as pass;


\echo
\echo '=== B. THE LEDGERS STAY SEPARATE ==='
-- The invariant that matters most. An order for a jumper is not a lesson fee.

select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
create temp table _it as select
  (public.shop_item_save(null,'School Jumper','Navy, embroidered',25,'["S","M","L"]'::jsonb,10,null)->>'id')::uuid as jumper,
  (public.shop_item_save(null,'Dance Shoes',null,40,'["28","30","32"]'::jsonb,null,null)->>'id')::uuid as shoes,
  (public.shop_item_save(null,'Water Bottle',null,8,'[]'::jsonb,3,null)->>'id')::uuid as bottle;

select 'three items were created' as t, count(*) = 3 as pass
  from public.shop_items where business_id='c1000000-0000-0000-0000-000000000001';

select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');

create temp table _before as
  select (select payments from public.cards where share_code='SHPIRA') as pmts,
         (select history  from public.cards where share_code='SHPIRA') as hist,
         pg_temp.fees_owed() as fees;

create temp table _o1 as
  select public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
    jsonb_build_array(
      jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',2),
      jsonb_build_object('item_id',(select shoes  from _it),'size','30','qty',1)), 'For the recital') as r;

select 'the order is placed' as t, ((select r from _o1)->>'ok')::boolean as pass;

select 'priced from the items table: 2 x 25 + 40' as t,
       ((select r from _o1)->>'total')::numeric = 90 as pass;

select 'the student''s card is untouched, byte for byte' as t,
       payments = (select pmts from _before) as pass
  from public.cards where share_code='SHPIRA';

select 'no payment history entry was written' as t,
       history = (select hist from _before) as pass
  from public.cards where share_code='SHPIRA';

select 'the school is owed exactly the same in FEES as before' as t,
       pg_temp.fees_owed() = (select fees from _before) as pass;

select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select 'and the kit debt is counted separately, in its own total' as t,
       (public.shop_orders_queue()->>'owed')::numeric = 90 as pass;

create temp table _pay1 as
  select public.shop_order_mark_paid_owner((select (r->>'order')::uuid from _o1)) as r;
select 'settling the order succeeds' as t, ((select r from _pay1)->>'ok')::boolean as pass;
select 'and still does not touch the card' as t,
       payments = (select pmts from _before) and history = (select hist from _before) as pass
  from public.cards where share_code='SHPIRA';

select 'and the fee total is still untouched' as t,
       pg_temp.fees_owed() = (select fees from _before) as pass;


\echo
\echo '=== C. what a parent may order ==='
select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');

select 'an item needing a size cannot be ordered without one' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'qty',1)))->>'error' = 'bad_size' as pass;

select 'nor with a size the item does not offer' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'size','XXL','qty',1)))->>'error' = 'bad_size' as pass;

select 'a zero quantity is refused' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',0)))->>'error' = 'bad_qty' as pass;

select 'an empty order is refused' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca','[]'::jsonb)->>'error' = 'bad_lines' as pass;

select 'a parent cannot order against a child that is not theirs' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000cb',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',1)))->>'error' = 'no_match' as pass;

select 'nor against another school''s student' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000cc',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',1)))->>'error' = 'no_match' as pass;

select pg_temp.act_as(null,null);
select 'a logged-out caller orders nothing' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',1)))->>'error' = 'not_authenticated' as pass;

-- An archived item is off the shelf, not merely hidden.
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select public.shop_item_archive((select bottle from _it), true) is not null as _setup;
select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');
select 'an archived item cannot be ordered' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select bottle from _it),'qty',1)))->>'error' = 'bad_item' as pass;
select 'and a parent is not shown it' as t,
       not (public.shop_catalogue_mine()->0->'items')::text like '%Water Bottle%' as pass;
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select public.shop_item_archive((select bottle from _it), false) is not null as _setup;


\echo
\echo '=== D. an order is a record of what was agreed ==='
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');

select public.shop_item_save((select jumper from _it),'School Jumper','Navy',99,'["S","M","L"]'::jsonb,10,null) is not null as _setup;

select 'raising the price later does not change an order already placed' as t,
       (select total from public.shop_orders where id = (select (r->>'order')::uuid from _o1)) = 90 as pass;

select 'the line still says what it cost at the time' as t,
       count(*) = 1 as pass
  from public.shop_order_lines
 where order_id = (select (r->>'order')::uuid from _o1)
   and item_name = 'School Jumper' and unit_price = 25 and qty = 2;

select public.shop_item_save((select jumper from _it),'School Jumper','Navy, embroidered',25,'["S","M","L"]'::jsonb,8,null) is not null as _setup;


\echo
\echo '=== E. STOCK CANNOT OVERSELL ==='
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
create temp table _sc as select
  (public.shop_item_save(null,'Last Two Caps',null,5,'[]'::jsonb,2,null)->>'id')::uuid as cap;

select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');
select 'ordering within stock works' as t,
       (public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select cap from _sc),'qty',2)))->>'ok')::boolean as pass;

select 'and the count came down' as t, stock = 0 as pass
  from public.shop_items where id = (select cap from _sc);

select 'the next order is refused rather than going negative' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select cap from _sc),'qty',1)))->>'error' = 'out_of_stock' as pass;

select 'stock never went below zero' as t, stock = 0 as pass
  from public.shop_items where id = (select cap from _sc);

select 'a parent is told it is out of stock, and never a number' as t,
       (select (i->>'out_of_stock')::boolean and not (i ? 'stock')
          from jsonb_array_elements(public.shop_catalogue_mine()->0->'items') i
         where i->>'name' = 'Last Two Caps') as pass;

-- An order asking for more than is left must leave the whole order unmade,
-- not a half-filled one.
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select public.shop_item_save((select cap from _sc),'Last Two Caps',null,5,'[]'::jsonb,1,null) is not null as _setup;
create temp table _n1 as select count(*) as n from public.shop_orders;
select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');
select 'a part-fillable order is refused whole' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(
           jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',1),
           jsonb_build_object('item_id',(select cap from _sc),'qty',5)))->>'error' = 'out_of_stock' as pass;
select 'and no half-order was left behind' as t,
       (select count(*) from public.shop_orders) = (select n from _n1) as pass;
select 'nor was the jumper''s stock quietly spent on it' as t, stock = 8 as pass
  from public.shop_items where id = (select jumper from _it);

-- Where stock is null, none of this applies at all.
select 'an item not counting stock can be ordered any number of times' as t,
       count(*) = 3 as pass
  from (select public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
          jsonb_build_array(jsonb_build_object('item_id',(select shoes from _it),'size','28','qty',9)))->>'ok' o
          from generate_series(1,3)) q
 where o = 'true';

select 'and its stock is still not being counted' as t, stock is null as pass
  from public.shop_items where id = (select shoes from _it);


\echo
\echo '=== F. the queue, and the payment seam ==='
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');

create temp table _q as select public.shop_orders_queue() as r;
select 'the owner sees their orders' as t,
       jsonb_array_length((select r from _q)->'orders') >= 1 as pass;

select 'with the student, the lines and a total' as t,
       (select bool_and(o->>'student' is not null
                    and jsonb_array_length(o->'lines') >= 1
                    and (o->>'total')::numeric >= 0)
          from jsonb_array_elements((select r from _q)->'orders') o) as pass;

create temp table _o2 as select id from public.shop_orders
 where payment_status = 'unpaid' and status = 'new' order by created_at limit 1;

select 'an order moves new -> ready -> collected' as t,
       (public.shop_order_set_status((select id from _o2),'ready')->>'ok')::boolean
   and (public.shop_order_set_status((select id from _o2),'collected')->>'ok')::boolean as pass;

select 'and collecting is timestamped' as t, collected_at is not null as pass
  from public.shop_orders where id = (select id from _o2);

select 'a nonsense status is refused' as t,
       public.shop_order_set_status((select id from _o2),'posted')->>'error' = 'bad_status' as pass;

-- The seam. One function, many callers, and it is reachable by none of them
-- directly.
create temp table _mp as
  select public.shop_order_mark_paid_owner((select id from _o2),'manual') as r;
select 'marking paid succeeds' as t, ((select r from _mp)->>'ok')::boolean as pass;
select 'and records HOW it was paid' as t,
       paid_via = 'manual' and paid_at is not null and payment_status = 'paid' as pass
  from public.shop_orders where id = (select id from _o2);

select 'paying twice is refused' as t,
       public.shop_order_mark_paid_owner((select id from _o2))->>'error' = 'already_paid' as pass;

create temp table _un as
  select public.shop_order_unmark_paid((select id from _o2)) as r;
select 'the owner can undo a payment they marked in error' as t,
       ((select r from _un)->>'ok')::boolean as pass;
select 'and the order is unpaid again, with no trace of how' as t,
       payment_status = 'unpaid' and paid_via is null and paid_at is null as pass
  from public.shop_orders where id = (select id from _o2);

select 'a via nobody supports yet is refused at the entry point' as t,
       public.shop_order_mark_paid_owner((select id from _o2),'stripe')->>'error' = 'bad_via' as pass;

create temp table _cap0 as select stock as s from public.shop_items where id=(select cap from _sc);
create temp table _cano as select o.id from public.shop_orders o
  where o.business_id='c1000000-0000-0000-0000-000000000001'
    and o.status <> 'cancelled'
    and exists (select 1 from public.shop_order_lines l
                 where l.order_id = o.id and l.item_id = (select cap from _sc))
  limit 1;
select public.shop_order_set_status((select id from _cano),'cancelled') is not null as _setup;
select 'cancelling puts counted stock back' as t,
       stock > (select s from _cap0) as pass
  from public.shop_items where id = (select cap from _sc);

select pg_temp.act_as('c0000000-0000-0000-0000-00000000000b','shop-other@t.example');
select 'another school sees none of these orders' as t,
       jsonb_array_length(public.shop_orders_queue()->'orders') = 0 as pass;
select 'and cannot move one along' as t,
       public.shop_order_set_status((select id from _o2),'ready')->>'error' = 'no_match' as pass;
select 'nor mark one paid' as t,
       public.shop_order_mark_paid_owner((select id from _o2))->>'error' = 'no_match' as pass;
select 'nor see another school''s items' as t,
       jsonb_array_length(public.shop_items_list()->'items') = 0 as pass;


\echo
\echo '=== G. a parent''s claim is not a payment either ==='
select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');

create temp table _o3 as select id from public.shop_orders
 where ordered_by = 'shop-parent@t.example' and payment_status = 'unpaid'
   and status <> 'cancelled' order by created_at limit 1;

select 'a parent can say they paid for an order' as t,
       (public.shop_order_claim_paid((select id from _o3), 90, current_date, 'REV-77')->>'ok')::boolean as pass;

select 'which marks it claimed, NOT paid' as t,
       payment_status = 'claimed' and paid_at is null as pass
  from public.shop_orders where id = (select id from _o3);

-- The parent's own view has to echo the claim back, and has to keep calling it
-- unpaid. The portal draws "Not marked paid yet" from exactly these two fields.
select 'the parent sees their own claim echoed back' as t,
       (select (o->>'claim_amount')::numeric = 90 and o->>'payment_status' = 'claimed'
          from jsonb_array_elements(public.shop_orders_mine()) o
         where o->>'id' = (select id::text from _o3)) as pass;

select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select 'so the school is still owed for it' as t,
       (public.shop_orders_queue()->>'owed')::numeric > 0 as pass;

select 'the owner sees what the parent said' as t,
       (select (o->>'claim_amount')::numeric = 90 and o->>'claim_ref' = 'REV-77'
          from jsonb_array_elements(public.shop_orders_queue()->'orders') o
         where o->>'id' = (select id::text from _o3)) as pass;

create temp table _cf as
  select public.shop_order_mark_paid_owner((select id from _o3),'link') as r;
select 'confirming a claim succeeds' as t, ((select r from _cf)->>'ok')::boolean as pass;
select 'and it went through the same seam, recorded as a link payment' as t,
       payment_status = 'paid' and paid_via = 'link' as pass
  from public.shop_orders where id = (select id from _o3);

select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c1','shop-parent2@t.example');
select 'a parent cannot claim against somebody else''s order' as t,
       public.shop_order_claim_paid((select id from _o3), 10, current_date)->>'error' = 'no_match' as pass;
select 'and sees none of their orders' as t,
       public.shop_orders_mine() = '[]'::jsonb as pass;


\echo
\echo '=== H. switching it off leaves nothing behind ==='
select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select 'the owner switches the shop off' as t,
       (public.shop_settings_set(false)->>'enabled')::boolean = false as pass;

select pg_temp.act_as('c0000000-0000-0000-0000-0000000000c0','shop-parent@t.example');
select 'the parent is offered nothing at all -- not an empty catalogue' as t,
       public.shop_catalogue_mine() = '[]'::jsonb as pass;

select 'and can no longer order' as t,
       public.shop_order_place('c2000000-0000-0000-0000-0000000000ca',
         jsonb_build_array(jsonb_build_object('item_id',(select jumper from _it),'size','M','qty',1)))->>'error' = 'shop_off' as pass;

select pg_temp.act_as('c0000000-0000-0000-0000-00000000000a','shop-owner@t.example');
select 'but nothing already sold was deleted' as t, count(*) > 0 as pass
  from public.shop_orders where business_id='c1000000-0000-0000-0000-000000000001';

select public.shop_settings_set(true) is not null as _setup;
select 'and switching it back on restores the catalogue intact' as t,
       jsonb_array_length(public.shop_items_list()->'items') >= 3 as pass;


\echo
\echo '=== I. the module touches nothing outside itself ==='

select 'every table it added is prefixed shop_' as t, count(*) = 4 as pass
  from information_schema.tables
 where table_schema = 'public' and table_name like 'shop\_%';

select 'and every function too' as t, count(*) = 16 as pass
  from pg_proc where proname like 'shop\_%';

-- If this ever fails, the module has stopped being removable: something
-- outside it would have to be put back by hand.
select 'businesses gained no shop column, so the module can just be dropped' as t,
       count(*) = 0 as pass
  from information_schema.columns
 where table_name = 'businesses' and column_name like '%shop%';

select 'and cards gained none either' as t, count(*) = 0 as pass
  from information_schema.columns
 where table_name = 'cards' and column_name like '%shop%';


\echo
\echo '=== J. grants ==='

select 'every shop table is function-internal' as t, count(*) = 0 as pass
  from information_schema.role_table_grants
 where table_name like 'shop\_%' and grantee in ('anon','authenticated');

select 'anon reaches nothing in the module' as t, count(*) = 0 as pass
  from pg_proc p where p.proname like 'shop\_%'
   and has_function_privilege('anon', p.oid, 'execute');

-- The seam settles an order without asking who wants it settled, so nothing
-- outside the module may call it directly.
select 'the payment seam and the two helpers are callable by nobody' as t,
       count(*) = 0 as pass
  from pg_proc p
 where p.proname in ('shop_order_mark_paid','shop_my_business','shop_is_enabled')
   and (has_function_privilege('anon', p.oid, 'execute')
     or has_function_privilege('authenticated', p.oid, 'execute'));

select 'and the thirteen entry points are reachable when logged in' as t,
       count(*) = 13 as pass
  from pg_proc p where p.proname like 'shop\_%'
   and has_function_privilege('authenticated', p.oid, 'execute');
