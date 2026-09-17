-- ===========================================================================
--  School shop  (OPTIONAL MODULE)
--  -------------------------------------------------------------------------
--  Uniforms, shoes, accessories. Sold by a school to its own students,
--  collected at the school. No shipping, no public storefront, no catalogue
--  anybody outside the school can see.
--
--  BUILT TO BE REMOVABLE. Everything here is new: four tables, all prefixed
--  shop_, and functions with the same prefix. Nothing in this file alters an
--  existing table, an existing function or an existing grant. Deleting the
--  module is the rollback block at the foot of this file and nothing else --
--  no column to drop from businesses, no function to restore to an earlier
--  shape, no data to migrate back.
--
--  That constraint drove two decisions worth knowing about:
--
--   1. The per-school switch lives in shop_settings, NOT in a column on
--      businesses. A column there would have been simpler and would have made
--      the module permanent: you cannot drop it without an ALTER on a table
--      the rest of the product depends on.
--
--   2. A parent saying they have paid for an order is recorded ON THE ORDER,
--      not in payment_claims. Reusing that table would have meant teaching
--      payment_claim_confirm about orders -- editing existing code, and
--      making its removal a revert rather than a drop. The order already has
--      a payment status and the owner already has a queue to look at, so the
--      claim belongs there.
--
--  AND THE LEDGERS STAY SEPARATE. Nothing in this file writes to cards.payments
--  or reads it. "Who owes me for September" is a question about lesson fees and
--  stays that way; a debt for a pair of shoes is a different question with a
--  different answer, and mixing them would make both useless. The test asserts
--  it the same way the payment-link suite does: by photographing a card and the
--  school's owed total before and after an order, and comparing.
--
--  Additive. Four tables. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. The switch
--
--  Off by default, and off means ABSENT: a school with no row here, or a row
--  with enabled = false, has no shop. Every read path below checks it, so
--  disabling leaves nothing behind in a parent's portal -- not an empty
--  section, not a heading with nothing under it.
--
--  Existing orders and items are NOT deleted when it is switched off. A school
--  turning the shop off for a term should not lose what it sold last term.
-- ---------------------------------------------------------------------------

create table if not exists public.shop_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  enabled     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.shop_settings enable row level security;
revoke all on table public.shop_settings from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  2. What is for sale
--
--  sizes is a plain array of labels -- 'S','M','L' or '28','30','32' -- and an
--  empty one means the item has no size to choose. stock is nullable ON
--  PURPOSE: null is "not counting", 0 is "counted, and there are none left".
--  Those are different things and the difference is the whole of the stock
--  behaviour below.
--
--  Archived rather than deleted, because an order from last term still refers
--  to the item and its history should not develop a hole.
-- ---------------------------------------------------------------------------

create table if not exists public.shop_items (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 80),
  description text check (description is null or length(description) <= 500),
  price       numeric not null check (price >= 0 and price <= 10000),
  sizes       jsonb not null default '[]'::jsonb,
  stock       int check (stock is null or stock >= 0),
  image_url   text check (image_url is null
                          or image_url ~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}(/[^\s]*)?$'),
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists shop_items_biz_idx
  on public.shop_items(business_id, archived_at, name);

alter table public.shop_items enable row level security;
revoke all on table public.shop_items from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  3. Orders, and the lines that make them up
--
--  A line carries its own copy of the item's name and price. Not
--  denormalisation for speed -- it is what makes an order a record of what was
--  actually agreed. Edit the price of a jumper next month and every order
--  already placed still says what that family owes.
--
--  payment_status has three values, and 'claimed' is the middle one for the
--  same reason the fee flow has a pending queue: a parent saying they paid is
--  not the school having been paid.
--
--  paid_via is the seam. Every route that can settle an order writes its name
--  here -- 'manual' today, 'link' today, 'stripe' when there is somewhere to
--  run a webhook -- so the school can always see how a thing came to be paid.
-- ---------------------------------------------------------------------------

create table if not exists public.shop_orders (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  card_id        uuid not null references public.cards(id) on delete cascade,
  ordered_by     text not null,
  status         text not null default 'new'
                   check (status in ('new','ready','collected','cancelled')),
  payment_status text not null default 'unpaid'
                   check (payment_status in ('unpaid','claimed','paid')),
  total          numeric not null check (total >= 0),
  note           text check (note is null or length(note) <= 300),

  -- Settlement. paid_via is deliberately open-ended text rather than an enum:
  -- a new trigger should be able to record itself without a migration.
  paid_via       text,
  paid_by        text,
  paid_at        timestamptz,

  -- A parent's unconfirmed word that they paid. On the order, not in a
  -- separate queue -- see the header.
  claim_amount   numeric check (claim_amount is null or claim_amount > 0),
  claim_date     date,
  claim_ref      text check (claim_ref is null or length(btrim(claim_ref)) <= 40),
  claimed_at     timestamptz,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  collected_at   timestamptz
);

create index if not exists shop_orders_queue_idx
  on public.shop_orders(business_id, status, created_at desc);
create index if not exists shop_orders_card_idx
  on public.shop_orders(card_id, created_at desc);

alter table public.shop_orders enable row level security;
revoke all on table public.shop_orders from public, anon, authenticated;


create table if not exists public.shop_order_lines (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.shop_orders(id) on delete cascade,
  item_id    uuid references public.shop_items(id) on delete set null,
  item_name  text not null,
  size       text,
  qty        int not null check (qty > 0 and qty <= 50),
  unit_price numeric not null check (unit_price >= 0),
  line_total numeric not null check (line_total >= 0)
);

create index if not exists shop_order_lines_order_idx
  on public.shop_order_lines(order_id);

alter table public.shop_order_lines enable row level security;
revoke all on table public.shop_order_lines from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  Small helpers. Both internal.
-- ---------------------------------------------------------------------------

create or replace function public.shop_my_business()
returns public.businesses
language sql
stable
security definer
set search_path = public
as $$
  select * from public.businesses where owner_id = auth.uid() limit 1;
$$;

create or replace function public.shop_is_enabled(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select enabled from public.shop_settings
                    where business_id = p_business_id), false);
$$;


-- ===========================================================================
--  4. The owner's side
-- ===========================================================================

create or replace function public.shop_settings_get()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz public.businesses%rowtype;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  return jsonb_build_object('ok', true, 'enabled', public.shop_is_enabled(v_biz.id));
end;
$$;


create or replace function public.shop_settings_set(p_enabled boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz public.businesses%rowtype;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  insert into public.shop_settings(business_id, enabled) values (v_biz.id, p_enabled)
  on conflict (business_id) do update set enabled = excluded.enabled, updated_at = now();
  return jsonb_build_object('ok', true, 'enabled', p_enabled);
end;
$$;


-- ---------------------------------------------------------------------------
--  shop_items_list -- the owner's catalogue, archived items included so they
--  can be brought back.
-- ---------------------------------------------------------------------------

create or replace function public.shop_items_list()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_biz public.businesses%rowtype;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  return jsonb_build_object('ok', true, 'enabled', public.shop_is_enabled(v_biz.id),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'name', i.name, 'description', i.description,
               'price', i.price, 'sizes', i.sizes, 'stock', i.stock,
               'image_url', i.image_url, 'archived', i.archived_at is not null)
             order by (i.archived_at is not null), i.name)
        from public.shop_items i where i.business_id = v_biz.id), '[]'::jsonb));
end;
$$;


create or replace function public.shop_item_save(
  p_id uuid, p_name text, p_description text, p_price numeric,
  p_sizes jsonb, p_stock int, p_image_url text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_biz public.businesses%rowtype;
  v_id  uuid;
  v_sizes jsonb := coalesce(p_sizes, '[]'::jsonb);
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;

  if p_name is null or length(btrim(p_name)) = 0 or length(btrim(p_name)) > 80 then
    return jsonb_build_object('error','bad_name');
  end if;
  if p_price is null or p_price < 0 or p_price > 10000 then
    return jsonb_build_object('error','bad_price');
  end if;
  if p_stock is not null and p_stock < 0 then
    return jsonb_build_object('error','bad_stock');
  end if;
  if jsonb_typeof(v_sizes) <> 'array' or jsonb_array_length(v_sizes) > 20 then
    return jsonb_build_object('error','bad_sizes');
  end if;

  if p_id is null then
    insert into public.shop_items(business_id, name, description, price, sizes, stock, image_url)
      values (v_biz.id, btrim(p_name), nullif(btrim(coalesce(p_description,'')),''),
              round(p_price,2), v_sizes, p_stock, nullif(btrim(coalesce(p_image_url,'')),''))
      returning id into v_id;
  else
    update public.shop_items
       set name = btrim(p_name),
           description = nullif(btrim(coalesce(p_description,'')),''),
           price = round(p_price,2), sizes = v_sizes, stock = p_stock,
           image_url = nullif(btrim(coalesce(p_image_url,'')),''),
           updated_at = now()
     where id = p_id and business_id = v_biz.id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('error','no_match'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when check_violation then
  return jsonb_build_object('error','bad_image');
end;
$$;


create or replace function public.shop_item_archive(p_id uuid, p_archived boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_biz public.businesses%rowtype;
  v_id  uuid;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  update public.shop_items
     set archived_at = case when p_archived then now() else null end, updated_at = now()
   where id = p_id and business_id = v_biz.id
   returning id into v_id;
  if v_id is null then return jsonb_build_object('error','no_match'); end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  5. The parent's side
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  shop_catalogue_mine -- what this parent can buy, per child.
--
--  Returns nothing at all for a school with the shop switched off. Not an
--  empty catalogue -- nothing -- so the portal has no section to draw.
-- ---------------------------------------------------------------------------

create or replace function public.shop_catalogue_mine()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_email text := auth.email();
begin
  if v_email is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'card_id', c.id, 'student', c.name, 'school', b.name,
             'items', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', i.id, 'name', i.name, 'description', i.description,
                        'price', i.price, 'sizes', i.sizes,
                        -- A parent is told "out of stock", never a number. The
                        -- count is the school's business, not the shop front's.
                        'out_of_stock', i.stock is not null and i.stock <= 0,
                        'image_url', i.image_url)
                      order by i.name)
                 from public.shop_items i
                where i.business_id = b.id and i.archived_at is null), '[]'::jsonb))
           order by c.name)
      from public.card_links cl
      join public.cards c      on c.id = cl.card_id
      join public.businesses b on b.id = c.business_id
     where cl.parent_email = v_email
       and public.shop_is_enabled(b.id)
  ), '[]'::jsonb);
end;
$$;


-- ---------------------------------------------------------------------------
--  shop_order_place -- the only way an order comes into being.
--
--  Lines arrive as [{item_id, size, qty}]. Everything priced here, from the
--  items table, never from the browser: a total the page computed would be a
--  total the page could choose.
--
--  Stock, where it is being counted, is decremented inside the same statement
--  that checks it -- `set stock = stock - qty where stock >= qty` -- so two
--  parents ordering the last jumper at the same moment cannot both get it.
--  Where stock is null nothing is checked and nothing is decremented.
-- ---------------------------------------------------------------------------

create or replace function public.shop_order_place(p_card_id uuid, p_lines jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.email();
  v_card  public.cards%rowtype;
  v_biz   public.businesses%rowtype;
  v_order uuid;
  v_total numeric := 0;
  r       jsonb;
  v_item  public.shop_items%rowtype;
  v_qty   int;
  v_size  text;
  v_got   uuid;
  n       int;
begin
  if v_email is null then return jsonb_build_object('error','not_authenticated'); end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('error','bad_lines');
  end if;
  n := jsonb_array_length(p_lines);
  if n = 0 or n > 20 then return jsonb_build_object('error','bad_lines'); end if;

  select c.* into v_card
    from public.cards c
    join public.card_links cl on cl.card_id = c.id
   where c.id = p_card_id and cl.parent_email = v_email;
  if not found then return jsonb_build_object('error','no_match'); end if;

  select * into v_biz from public.businesses where id = v_card.business_id;
  if not public.shop_is_enabled(v_biz.id) then
    return jsonb_build_object('error','shop_off');
  end if;

  insert into public.shop_orders(business_id, card_id, ordered_by, total, note)
    values (v_biz.id, v_card.id, v_email, 0,
            nullif(btrim(coalesce(p_note,'')),''))
    returning id into v_order;

  for r in select * from jsonb_array_elements(p_lines) loop
    v_qty  := coalesce((r->>'qty')::int, 0);
    v_size := nullif(btrim(coalesce(r->>'size','')),'');
    if v_qty < 1 or v_qty > 50 then
      raise exception using errcode = 'check_violation', message = 'bad_qty';
    end if;

    select * into v_item from public.shop_items
     where id = (r->>'item_id')::uuid
       and business_id = v_biz.id
       and archived_at is null;
    if not found then
      raise exception using errcode = 'no_data_found', message = 'bad_item';
    end if;

    -- A size must be one the item actually offers, and an item with sizes
    -- cannot be ordered without choosing one.
    if jsonb_array_length(v_item.sizes) > 0 then
      if v_size is null or not (v_item.sizes ? v_size) then
        raise exception using errcode = 'no_data_found', message = 'bad_size';
      end if;
    else
      v_size := null;
    end if;

    if v_item.stock is not null then
      update public.shop_items
         set stock = stock - v_qty, updated_at = now()
       where id = v_item.id and stock >= v_qty
       returning id into v_got;
      if v_got is null then
        raise exception using errcode = 'no_data_found', message = 'out_of_stock';
      end if;
    end if;

    insert into public.shop_order_lines(order_id, item_id, item_name, size, qty, unit_price, line_total)
      values (v_order, v_item.id, v_item.name, v_size, v_qty, v_item.price,
              round(v_item.price * v_qty, 2));
    v_total := v_total + round(v_item.price * v_qty, 2);
  end loop;

  update public.shop_orders set total = v_total where id = v_order;

  return jsonb_build_object('ok', true, 'order', v_order, 'total', v_total);
exception
  when no_data_found then
    return jsonb_build_object('error', sqlerrm);
  when check_violation then
    return jsonb_build_object('error', sqlerrm);
end;
$$;


create or replace function public.shop_orders_mine()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_email text := auth.email();
begin
  if v_email is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'card_id', o.card_id, 'student', c.name,
             'status', o.status, 'payment_status', o.payment_status,
             'total', o.total, 'created_at', o.created_at,
             -- Echoed back so the parent's own claim reads as theirs, and as
             -- unconfirmed. The school's side of it is not exposed here.
             'claim_amount', o.claim_amount, 'claim_date', o.claim_date,
             'lines', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'name', l.item_name, 'size', l.size,
                        'qty', l.qty, 'line_total', l.line_total))
                 from public.shop_order_lines l where l.order_id = o.id), '[]'::jsonb))
           order by o.created_at desc)
      from public.shop_orders o
      join public.cards c on c.id = o.card_id
     where o.ordered_by = v_email
       and (o.status <> 'collected' or o.updated_at > now() - interval '30 days')
  ), '[]'::jsonb);
end;
$$;


-- ===========================================================================
--  6. THE PAYMENT SEAM
-- ===========================================================================
--
--  shop_order_mark_paid is the ONE function that settles an order. Every route
--  goes through it: the owner ticking it off, a confirmed payment-link claim,
--  and -- when there is somewhere to run a webhook -- a card processor. None of
--  them re-implements what being paid means.
--
--  It authorises NOTHING. It is handed an order its caller has already
--  established the right to settle, which is why it is granted to nobody. Each
--  entry point below does the proving, exactly as stamp_apply_payment does for
--  the fee side.
--
--  To add a processor later: verify the webhook, find the order, call this with
--  p_via = 'stripe'. Nothing else in this file needs to change.
-- ---------------------------------------------------------------------------

create or replace function public.shop_order_mark_paid(
  p_order_id uuid, p_via text, p_by text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_done uuid; v_o public.shop_orders%rowtype;
begin
  select * into v_o from public.shop_orders where id = p_order_id;
  if not found then return jsonb_build_object('error','no_match'); end if;
  if v_o.status = 'cancelled' then
    return jsonb_build_object('error','cancelled');
  end if;

  -- Claimed first, so two routes settling the same order at the same moment
  -- cannot both report having done it.
  update public.shop_orders
     set payment_status = 'paid', paid_via = p_via, paid_by = p_by,
         paid_at = now(), updated_at = now()
   where id = p_order_id and payment_status <> 'paid'
   returning id into v_done;
  if v_done is null then return jsonb_build_object('error','already_paid'); end if;

  return jsonb_build_object('ok', true, 'order', p_order_id,
                            'total', v_o.total, 'via', p_via);
end;
$$;


-- ===========================================================================
--  7. The owner's queue
-- ===========================================================================

create or replace function public.shop_orders_queue()
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_biz public.businesses%rowtype;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;

  return jsonb_build_object('ok', true,
    'enabled', public.shop_is_enabled(v_biz.id),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'student', c.name, 'status', o.status,
               'payment_status', o.payment_status, 'total', o.total,
               'ordered_by', o.ordered_by, 'note', o.note,
               'paid_via', o.paid_via, 'created_at', o.created_at,
               'claim_amount', o.claim_amount, 'claim_date', o.claim_date,
               'claim_ref', o.claim_ref,
               'lines', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'name', l.item_name, 'size', l.size,
                          'qty', l.qty, 'line_total', l.line_total))
                   from public.shop_order_lines l where l.order_id = o.id), '[]'::jsonb))
             order by (o.status = 'collected' or o.status = 'cancelled'), o.created_at)
        from public.shop_orders o
        join public.cards c on c.id = o.card_id
       where o.business_id = v_biz.id
         and (o.status not in ('collected','cancelled')
              or o.updated_at > now() - interval '14 days')), '[]'::jsonb),
    -- The kit ledger, kept apart from the fee ledger on purpose.
    'owed', coalesce((select sum(o.total) from public.shop_orders o
                       where o.business_id = v_biz.id
                         and o.payment_status <> 'paid'
                         and o.status <> 'cancelled'), 0));
end;
$$;


create or replace function public.shop_order_set_status(p_order_id uuid, p_status text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_biz public.businesses%rowtype;
  v_id  uuid;
  v_o   public.shop_orders%rowtype;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  if p_status not in ('new','ready','collected','cancelled') then
    return jsonb_build_object('error','bad_status');
  end if;

  select * into v_o from public.shop_orders
   where id = p_order_id and business_id = v_biz.id;
  if not found then return jsonb_build_object('error','no_match'); end if;

  -- Cancelling puts counted stock back. Uncounted stock stays uncounted.
  if p_status = 'cancelled' and v_o.status <> 'cancelled' then
    update public.shop_items i
       set stock = i.stock + l.qty, updated_at = now()
      from public.shop_order_lines l
     where l.order_id = v_o.id and i.id = l.item_id and i.stock is not null;
  end if;

  update public.shop_orders
     set status = p_status, updated_at = now(),
         collected_at = case when p_status = 'collected' then now() else collected_at end
   where id = p_order_id and business_id = v_biz.id
   returning id into v_id;

  return jsonb_build_object('ok', true);
end;
$$;


-- ---------------------------------------------------------------------------
--  The owner settling an order. One of the seam's entry points; 'manual' when
--  they took cash, 'link' when they are confirming a claim a parent raised.
-- ---------------------------------------------------------------------------

create or replace function public.shop_order_mark_paid_owner(
  p_order_id uuid, p_via text default 'manual')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz public.businesses%rowtype;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  if p_via not in ('manual','link') then
    return jsonb_build_object('error','bad_via');
  end if;
  if not exists (select 1 from public.shop_orders
                  where id = p_order_id and business_id = v_biz.id) then
    return jsonb_build_object('error','no_match');
  end if;
  return public.shop_order_mark_paid(p_order_id, p_via, coalesce(auth.email(),'owner'));
end;
$$;


create or replace function public.shop_order_unmark_paid(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_biz public.businesses%rowtype; v_id uuid;
begin
  v_biz := public.shop_my_business();
  if v_biz.id is null then return jsonb_build_object('error','no_business'); end if;
  update public.shop_orders
     set payment_status = 'unpaid', paid_via = null, paid_by = null,
         paid_at = null, updated_at = now()
   where id = p_order_id and business_id = v_biz.id and payment_status = 'paid'
   returning id into v_id;
  if v_id is null then return jsonb_build_object('error','no_match'); end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- ---------------------------------------------------------------------------
--  The parent's unconfirmed word, recorded on the order. It does NOT settle
--  anything -- payment_status becomes 'claimed', which is not 'paid', and the
--  school's kit-owed total is unmoved until they confirm.
-- ---------------------------------------------------------------------------

create or replace function public.shop_order_claim_paid(
  p_order_id uuid, p_amount numeric, p_paid_on date, p_reference text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email(); v_id uuid;
begin
  if v_email is null then return jsonb_build_object('error','not_authenticated'); end if;
  if p_amount is null or p_amount <= 0 then return jsonb_build_object('error','bad_amount'); end if;
  if p_paid_on is null or p_paid_on > current_date
     or p_paid_on < current_date - interval '365 days' then
    return jsonb_build_object('error','bad_date');
  end if;

  update public.shop_orders
     set payment_status = 'claimed', claim_amount = round(p_amount,2),
         claim_date = p_paid_on,
         claim_ref = nullif(btrim(coalesce(p_reference,'')),''),
         claimed_at = now(), updated_at = now()
   where id = p_order_id and ordered_by = v_email
     and payment_status = 'unpaid' and status <> 'cancelled'
   returning id into v_id;
  if v_id is null then return jsonb_build_object('error','no_match'); end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  8. Grants
--
--  Every table is function-internal, as everywhere else in this codebase, and
--  each function checks for itself who is calling. shop_order_mark_paid and
--  the two helpers are granted to nobody: the first settles an order without
--  asking who wants it settled, and the helpers exist only to be called from
--  inside the others.
-- ===========================================================================

revoke all on function public.shop_order_mark_paid(uuid,text,text) from public, anon, authenticated;
revoke all on function public.shop_my_business()                   from public, anon, authenticated;
revoke all on function public.shop_is_enabled(uuid)                from public, anon, authenticated;

revoke all on function public.shop_settings_get()                                      from public, anon;
revoke all on function public.shop_settings_set(boolean)                               from public, anon;
revoke all on function public.shop_items_list()                                        from public, anon;
revoke all on function public.shop_item_save(uuid,text,text,numeric,jsonb,int,text)     from public, anon;
revoke all on function public.shop_item_archive(uuid,boolean)                           from public, anon;
revoke all on function public.shop_catalogue_mine()                                     from public, anon;
revoke all on function public.shop_order_place(uuid,jsonb,text)                         from public, anon;
revoke all on function public.shop_orders_mine()                                        from public, anon;
revoke all on function public.shop_orders_queue()                                       from public, anon;
revoke all on function public.shop_order_set_status(uuid,text)                           from public, anon;
revoke all on function public.shop_order_mark_paid_owner(uuid,text)                      from public, anon;
revoke all on function public.shop_order_unmark_paid(uuid)                               from public, anon;
revoke all on function public.shop_order_claim_paid(uuid,numeric,date,text)              from public, anon;

grant execute on function public.shop_settings_get()                                  to authenticated;
grant execute on function public.shop_settings_set(boolean)                           to authenticated;
grant execute on function public.shop_items_list()                                    to authenticated;
grant execute on function public.shop_item_save(uuid,text,text,numeric,jsonb,int,text) to authenticated;
grant execute on function public.shop_item_archive(uuid,boolean)                       to authenticated;
grant execute on function public.shop_catalogue_mine()                                 to authenticated;
grant execute on function public.shop_order_place(uuid,jsonb,text)                     to authenticated;
grant execute on function public.shop_orders_mine()                                    to authenticated;
grant execute on function public.shop_orders_queue()                                   to authenticated;
grant execute on function public.shop_order_set_status(uuid,text)                       to authenticated;
grant execute on function public.shop_order_mark_paid_owner(uuid,text)                  to authenticated;
grant execute on function public.shop_order_unmark_paid(uuid)                           to authenticated;
grant execute on function public.shop_order_claim_paid(uuid,numeric,date,text)          to authenticated;


-- ===========================================================================
--  REMOVING THE MODULE
--
--  This is the whole of it. Nothing outside these objects was changed, so
--  there is nothing else to put back.
--
--    drop function if exists public.shop_order_claim_paid(uuid,numeric,date,text);
--    drop function if exists public.shop_order_unmark_paid(uuid);
--    drop function if exists public.shop_order_mark_paid_owner(uuid,text);
--    drop function if exists public.shop_order_set_status(uuid,text);
--    drop function if exists public.shop_orders_queue();
--    drop function if exists public.shop_orders_mine();
--    drop function if exists public.shop_order_place(uuid,jsonb,text);
--    drop function if exists public.shop_catalogue_mine();
--    drop function if exists public.shop_item_archive(uuid,boolean);
--    drop function if exists public.shop_item_save(uuid,text,text,numeric,jsonb,int,text);
--    drop function if exists public.shop_items_list();
--    drop function if exists public.shop_settings_set(boolean);
--    drop function if exists public.shop_settings_get();
--    drop function if exists public.shop_order_mark_paid(uuid,text,text);
--    drop function if exists public.shop_is_enabled(uuid);
--    drop function if exists public.shop_my_business();
--    drop table if exists public.shop_order_lines;
--    drop table if exists public.shop_orders;
--    drop table if exists public.shop_items;
--    drop table if exists public.shop_settings;
--
--  In the app, delete the block between the SHOP MODULE markers and every line
--  marked "SHOP MODULE mount". Each mount is one whole line.
-- ===========================================================================
